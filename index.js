/**
 * dsh-native-tools：截图 / 剪贴板历史 / 翻译，三合一。
 *
 * 四个功能共用一个原生进程（`helper/DSHNative.app`），四个功能各自有一个开关，
 * 在插件设置页里单独打开或关掉；关掉的功能会被从进程里卸下来（热键注销、面板收起），
 * 全部关掉时整个进程退出。
 *
 * Host 半边只做三件事：
 *   1. 保证那个进程活着（自己 spawn，或接管别的会话已经拉起来的那个）；
 *   2. 把配置里每个功能的设置推给它（快捷键、保存目录、识别偏好、历史容量…）；
 *   3. 翻译请求要回 Host 处理：这边开一条 Unix socket，原生进程把要译的文本发过来。
 *
 * 为什么界面在原生进程里：DSH 桌面版把 Host 当作 Electron 主进程的子进程拉起，Host
 * 里没有 `globalShortcut`、`BrowserWindow`、`desktopCapturer`，做不了全屏覆盖层和全局
 * 热键。所以壳与键盘在 Swift，翻译通道、配置、日志都留在 Host。
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { createRequire } from "node:module";
import { connect } from "node:net";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";

import { startTranslateHost, DEFAULT_PROVIDER } from "./translate-host.js";

const PACKAGE_DIR = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

/**
 * schemastery 从 profile 里取：插件是以 link: 装进 profile 的符号链接，从包的真实
 * 路径直接 import 会解析失败。取不到就退化成「没有 Config」—— 插件仍然工作，只是
 * 设置页不可用。
 */
const schema = await (async () => {
  try {
    const require = createRequire(join(process.env.DSH_PROFILE_DIR ?? process.cwd(), "noop.cjs"));
    const loaded = await import(pathToFileURL(require.resolve("@deepseek-ai/schemastery")).href);
    return loaded.default ?? loaded;
  } catch {
    return undefined;
  }
})();

const DEFAULT_HOTKEYS = {
  screenshot: "cmd+shift+a",
  clipboard: "cmd+shift+v",
  translate: "cmd+shift+t",
};

/**
 * 字段分两类，区别在 DSH 怎么对待它们：
 *
 * - `.volatile()`（下面除 `appPath` 以外的全部字段）：改设置时 DSH 不重启插件，
 *   只把新值写进 volatile 引用，然后派发 `loader/volatile-update`。这些字段**只**
 *   在 `plugins.row.config` / `plugins.bundle.config` 的设置页里出现——Host 的
 *   `volatileForm()` 只把 volatile 字段投影进 settings 命名空间，一个 volatile
 *   字段都没有的插件，设置页就只会说「这个插件没有声明可配置项」。
 *   运行时读它们必须 `config.screenshot.enabled.get()`，见下面的 `field()`。
 * - 普通字段（`appPath`）：改它会让 DSH 重建插件，即重跑一次 `apply()`。
 */
export const Config = schema?.object({
  screenshot: schema.object({
    enabled: schema.boolean().default(true).volatile().description("拖框截图：复制、另存、加红框、识别文字"),
    hotkey: schema.string().default(DEFAULT_HOTKEYS.screenshot).volatile().description("截图快捷键，如 cmd+shift+a、ctrl+opt+a、f8。"),
    saveDirectory: schema.string().default("").volatile().description("「保存」按钮的默认目录，留空表示桌面。"),
    ocrLanguages: schema.string().default("auto").volatile().description("文字识别语言：auto（自动判断）、zh（中文优先）、en（英文优先）。"),
    ocrKeepLineBreaks: schema.boolean().default(true).volatile().description("文字识别时保留屏幕上的换行。"),
  }),
  clipboard: schema.object({
    enabled: schema.boolean().default(true).volatile().description("剪贴板历史面板：搜索、预览、回车粘贴"),
    hotkey: schema.string().default(DEFAULT_HOTKEYS.clipboard).volatile().description("剪贴板历史快捷键，如 cmd+shift+v。"),
    maxItems: schema.number().default(200).volatile().description("最多保留多少条历史记录。"),
    retentionDays: schema.number().default(30).volatile().description("历史记录保留多少天。"),
  }),
  translate: schema.object({
    enabled: schema.boolean().default(true).volatile().description("翻译浮窗：选中文本或输入框里按快捷键"),
    hotkey: schema.string().default(DEFAULT_HOTKEYS.translate).volatile().description("翻译快捷键，如 cmd+shift+t。"),
    provider: schema.string().default(DEFAULT_PROVIDER).volatile().description("翻译通道：bing、google 等（需要登录的通道会失败）。"),
    targetLanguage: schema.string().default("auto").volatile().description("目标语言：auto 表示中文进英文出、其他进中文。"),
  }),
  monitor: schema.object({
    enabled: schema.boolean().default(true).volatile().description("系统监控：菜单栏三个图标（网络上下行 / CPU / 内存），点开看占用最高的进程"),
    refreshSeconds: schema.number().default(2).volatile().description("采样间隔秒数，1–60。"),
    topCount: schema.number().default(8).volatile().description("点开图标后列出多少个进程，3–30。"),
    showNetwork: schema.boolean().default(true).volatile().description("显示网络图标（↓下行 ↑上行速率）。"),
    showCPU: schema.boolean().default(true).volatile().description("显示 CPU 图标（整机占用百分比）。"),
    showMemory: schema.boolean().default(true).volatile().description("显示内存图标（已用百分比）。"),
    networkDetailed: schema.boolean().default(true).volatile().description("网络图标是否同时显示上行速率，关掉只显示 ↓。"),
  }),
  appPath: schema.string().default("").description("helper 的 .app 路径，留空用包内 helper/DSHNative.app。"),
});

// ---------------------------------------------------------------------------
// 四个功能与它们的 socket
// ---------------------------------------------------------------------------

/**
 * 每个功能的 socket 与它自己的支持目录都沿用合并前的样子，所以已有配置、历史记录、
 * 用户手动改过的快捷键都不用迁移。`*_SOCKET` 环境变量优先（自测与多实例调试用）。
 */
const FEATURES = [
  {
    slug: "screenshot",
    label: "截图",
    supportDir: "DSHScreenshot",
    socketEnv: "DSHS_SCREENSHOT_SOCKET",
  },
  {
    slug: "clipboard",
    label: "剪贴板",
    supportDir: "DSHClipboard",
    socketEnv: "DSHS_CLIPBOARD_SOCKET",
  },
  {
    slug: "translate",
    label: "翻译",
    supportDir: "DSHTranslate",
    socketEnv: "DSHS_TRANSLATE_SOCKET",
  },
  {
    slug: "monitor",
    label: "系统监控",
    supportDir: "DSHMonitor",
    socketEnv: "DSHS_MONITOR_SOCKET",
  },
];

const DEFAULT_APP = join(PACKAGE_DIR, "helper", "DSHNative.app");
const RESTART_STEPS_MS = [500, 1_000, 2_000, 5_000, 10_000];
const HEALTH_INTERVAL_MS = 5_000;
const HEALTH_FAILURES_BEFORE_RESTART = 2;

function supportDirectory(feature) {
  return join(homedir(), "Library", "Application Support", feature.supportDir);
}

function socketPathFor(feature) {
  const override = process.env[feature.socketEnv];
  if (typeof override === "string" && override !== "") return override;
  return join(supportDirectory(feature), "control.sock");
}

/** 翻译请求回 Host 的那条通道（只有 translate 功能用）。 */
function translateHostSocketPath() {
  const override = process.env.DSHS_TRANSLATE_HOST_SOCKET;
  if (typeof override === "string" && override !== "") return override;
  return join(homedir(), "Library", "Application Support", "DSHTranslate", "host.sock");
}

/** 四个功能共享的那条通道：用来「加入已在跑的进程」与「按需装载/卸载功能」。 */
function nativeSocketPath() {
  const override = process.env.DSHS_NATIVE_SOCKET;
  if (typeof override === "string" && override !== "") return override;
  return join(homedir(), "Library", "Application Support", "DSHNative", "control.sock");
}

// ---------------------------------------------------------------------------
// 控制通道客户端
// ---------------------------------------------------------------------------

/**
 * 给 helper 发一条命令。**永不 reject**：helper 不在时返回 undefined，
 * 调用方只关心「有没有回 ok」。
 */
function sendControl(request, { timeout = 900, path = nativeSocketPath() } = {}) {
  return new Promise((resolve) => {
    let settled = false;
    let buffer = "";
    const socket = connect(path);
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(value);
    };
    const timer = setTimeout(() => finish(undefined), timeout);
    socket.setEncoding("utf8");
    socket.on("connect", () => {
      socket.write(`${JSON.stringify(request)}\n`);
    });
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      const line = buffer.slice(0, newline).trim();
      try {
        finish(JSON.parse(line));
      } catch {
        finish(undefined);
      }
    });
    socket.on("error", () => finish(undefined));
    socket.on("end", () => finish(undefined));
    socket.on("close", () => finish(undefined));
  });
}

// ---------------------------------------------------------------------------
// 插件主体
// ---------------------------------------------------------------------------

export function apply(ctx, config = {}) {
  if (process.platform !== "darwin") {
    ctx.logger?.info?.("dsh-native-tools: 原生助手只在 macOS 上运行，已跳过");
    return;
  }

  /**
   * volatile 字段在运行时是 `{ get() }` 引用（值随时会被设置页改写），普通字段就是值本身。
   * 读配置一律过 `field()`，任何时候读到的都是这一秒的值。
   */
  const val = (value) => (value !== null && typeof value === "object" && typeof value.get === "function"
    ? value.get()
    : value);

  const groups = config ?? {};
  const groupFor = (slug) => (typeof groups[slug] === "object" && groups[slug] !== null ? groups[slug] : {});
  const field = (slug, key) => val(groupFor(slug)[key]);
  const stringField = (slug, key) => {
    const value = field(slug, key);
    return typeof value === "string" ? value : "";
  };
  const isOn = (slug) => field(slug, "enabled") !== false;
  /** 现在该开着哪些功能。每次现算：设置页里拨了开关，下一次 sync 就跟上。 */
  const desired = () => FEATURES.filter((feature) => isOn(feature.slug));

  const configuredAppPath = val(groups.appPath);
  const appPath = typeof configuredAppPath === "string" && configuredAppPath !== "" ? configuredAppPath : DEFAULT_APP;
  if (desired().length > 0) {
    if (!existsSync(appPath)) {
      ctx.logger?.warn?.(`dsh-native-tools: 找不到 helper（${appPath}），四个功能都没启用；可用 appPath 指定`);
      return;
    }
    if (!existsSync(join(appPath, "Contents", "MacOS", "DSHNative"))) {
      ctx.logger?.warn?.(`dsh-native-tools: helper 缺少可执行文件（${appPath}），四个功能都没启用`);
      return;
    }
  }

  /** 这一个插件实例的身份：配置改动会重建插件，旧实例的 release 不能踢掉新实例的接管。 */
  const generation = randomUUID();

  /** 每个功能要推给 helper 的设置。空字符串/未定义一律不推，避免把用户改过的值打回默认。 */
  const settingsFor = (slug) => {
    const settings = {};
    const hotkey = stringField(slug, "hotkey").trim();
    if (hotkey !== "") settings.hotkey = hotkey;
    if (slug === "screenshot") {
      const directory = stringField(slug, "saveDirectory").trim();
      if (directory !== "") settings.saveDirectory = directory;
      const languages = stringField(slug, "ocrLanguages").trim();
      if (languages !== "") settings.ocrLanguages = languages;
      const keepLineBreaks = field(slug, "ocrKeepLineBreaks");
      if (typeof keepLineBreaks === "boolean") settings.ocrKeepLineBreaks = keepLineBreaks;
    }
    if (slug === "clipboard") {
      const maxItems = field(slug, "maxItems");
      const retentionDays = field(slug, "retentionDays");
      if (Number.isFinite(maxItems)) settings.maxItems = Math.floor(maxItems);
      if (Number.isFinite(retentionDays)) settings.retentionDays = Math.floor(retentionDays);
    }
    if (slug === "translate") {
      settings.hostSocket = translateHostSocketPath();
    }
    if (slug === "monitor") {
      const refreshSeconds = field(slug, "refreshSeconds");
      const topCount = field(slug, "topCount");
      if (Number.isFinite(refreshSeconds)) settings.refreshSeconds = Math.floor(refreshSeconds);
      if (Number.isFinite(topCount)) settings.topCount = Math.floor(topCount);
      for (const key of ["showNetwork", "showCPU", "showMemory", "networkDetailed"]) {
        const value = field(slug, key);
        if (typeof value === "boolean") settings[key] = value;
      }
    }
    return settings;
  };

  // ---- 翻译通道：只有翻译开着时才占用 socket -----------------------------

  let translateHost;

  /** 把翻译通道对齐到当前配置：关了就收掉，开着就起/就地换 provider 与目标语言。 */
  const syncTranslateHost = () => {
    if (disposing) return;
    if (!isOn("translate")) {
      translateHost?.close();
      translateHost = undefined;
      return;
    }
    const next = {
      provider: stringField("translate", "provider") || DEFAULT_PROVIDER,
      targetLanguage: stringField("translate", "targetLanguage") || "auto",
    };
    if (translateHost === undefined) {
      try {
        translateHost = startTranslateHost({ ctx, socketPath: translateHostSocketPath(), ...next });
      } catch (error) {
        ctx.logger?.warn?.(`dsh-native-tools: 翻译通道起不来（${error?.message ?? String(error)}）`);
        translateHost = undefined;
      }
      return;
    }
    translateHost.configure?.(next);
  };

  let child;
  let disposing = false;
  let attempts = 0;
  let restartTimer;
  let healthTimer;
  let healthFailures = 0;
  /** 已经接管到手的功能够成同步的基准：设置页拨了开关，就按它增删。 */
  const attached = new Set();
  /** 已经确认卸下的功能：避免每次 sync 都对着空 socket 重发一遍。 */
  const detached = new Set();

  const clearRestartTimer = () => {
    if (restartTimer !== undefined) {
      clearTimeout(restartTimer);
      restartTimer = undefined;
    }
  };

  /**
   * 接管一个功能：先问它自己的 socket（进程活着、功能已装载时直接成），
   * 不成再请共享通道按需装载后接管（进程活着但这个功能还没起来时走这条）。
   */
  const adoptFeature = async (feature, quiet = false) => {
    const request = {
      command: "adopt",
      parentPID: process.pid,
      generation,
      ...settingsFor(feature.slug),
    };
    const direct = await sendControl(request, { path: socketPathFor(feature) });
    if (direct?.ok === true) {
      attached.add(feature.slug);
      detached.delete(feature.slug);
      return true;
    }
    const joined = await sendControl(
      {
        ...request,
        feature: feature.slug,
        socket: socketPathFor(feature),
      },
      { path: nativeSocketPath() },
    );
    if (joined?.ok !== true) {
      if (!quiet) ctx.logger?.info?.(`dsh-native-tools: ${feature.label} 还没应答，稍后重试`);
      return false;
    }
    ctx.logger?.info?.(`dsh-native-tools: 加入已在跑的进程（${feature.label}，pid ${joined.pid ?? "?"}）`);
    attached.add(feature.slug);
    detached.delete(feature.slug);
    return true;
  };

  /** 把已经关掉的功能从进程里卸下来（热键注销、面板收起、socket 关闭）。 */
  const detachFeature = async (feature) => {
    attached.delete(feature.slug);
    const reply = await sendControl(
      { command: "detach-feature", feature: feature.slug },
      { path: nativeSocketPath() },
    );
    if (reply?.ok !== true) return undefined;
    detached.add(feature.slug);
    if (reply.alreadyDetached === true) return reply.remaining;
    ctx.logger?.info?.(`dsh-native-tools: 已卸下 ${feature.label}（还剩 ${reply.remaining ?? "?"} 个功能在跑）`);
    return reply.remaining;
  };

  /**
   * 自己 spawn 出来的进程也要登记一次：adopt 把 supervisor 与 generation 写进进程，
   * release 才对得上代号，配置改动才能「交接」而不是「杀掉」。
   *
   * helper 先打印 ready 再逐个开 feature 的控制通道，所以第一次 adopt 很可能碰上
   * socket 还没好的瞬间 —— 重试几次，别让它停在 attached:false。
   */
  let claiming = false;
  const claimChild = async (retriesLeft = 12) => {
    if (disposing || claiming) return;
    claiming = true;
    try {
      const adopted = await Promise.all(desired().map((feature) => adoptFeature(feature, retriesLeft > 1)));
      if (adopted.every(Boolean)) return;
      if (retriesLeft <= 1) {
        ctx.logger?.warn?.("dsh-native-tools: 接管原生进程失败，等探活重新接管");
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
      claiming = false;
      await claimChild(retriesLeft - 1);
    } finally {
      claiming = false;
    }
  };

  /**
   * 探活。自己 spawn 的进程有 exit 事件可听，但**接管来的没有**：进程一死这边无从
   * 得知，功能会静默消失，所以每个功能都要定期问一句。
   */
  const healthCheck = async () => {
    if (disposing) return;
    const wanted = desired();
    const replies = await Promise.all(
      wanted.map((feature) => sendControl({ command: "status" }, { path: socketPathFor(feature), timeout: 800 })),
    );
    const missing = wanted.filter((feature, index) => replies[index]?.ok !== true);
    if (missing.length === 0) {
      healthFailures = 0;
      return;
    }
    // 只丢了个别功能：让进程按需重新装回来。
    if (missing.length < wanted.length) {
      for (const feature of missing) await adoptFeature(feature);
      healthFailures = 0;
      return;
    }
    healthFailures += 1;
    if (healthFailures < HEALTH_FAILURES_BEFORE_RESTART) return;
    healthFailures = 0;
    ctx.logger?.warn?.("dsh-native-tools: 原生进程不响应，重新接管或拉起");
    let recovered = false;
    for (const feature of wanted) {
      recovered = (await adoptFeature(feature)) || recovered;
    }
    if (!recovered) startChild();
  };

  const startHealthMonitor = () => {
    if (disposing || healthTimer !== undefined) return;
    healthTimer = setInterval(() => void healthCheck(), HEALTH_INTERVAL_MS);
    healthTimer.unref?.();
  };

  const stopHealthMonitor = () => {
    if (healthTimer !== undefined) {
      clearInterval(healthTimer);
      healthTimer = undefined;
    }
  };

  const startChild = () => {
    const wanted = desired();
    if (disposing || wanted.length === 0) return;
    clearRestartTimer();
    const args = [];
    for (const feature of wanted) args.push("--feature", feature.slug);
    args.push("--parent-pid", String(process.pid));
    if (isOn("translate")) args.push("--host-socket", translateHostSocketPath());
    const started = spawn(join(appPath, "Contents", "MacOS", "DSHNative"), args, {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, DSHS_GENERATION: generation },
    });
    child = started;
    startHealthMonitor();
    started.stdout?.setEncoding("utf8");
    started.stdout?.on("data", (chunk) => {
      for (const line of String(chunk).split("\n")) {
        const trimmed = line.trim();
        if (trimmed === "") continue;
        try {
          const payload = JSON.parse(trimmed);
          if (payload?.event === "ready") {
            attempts = 0;
            ctx.logger?.info?.(`dsh-native-tools: 原生进程就绪（pid ${payload.pid ?? "?"}）`);
            // 进程刚起：把它登记成自己的子进程，并把设置推过去。
            void claimChild();
            continue;
          }
          if (payload?.event === "feature-ready") {
            ctx.logger?.info?.(
              `dsh-native-tools: ${payload.feature ?? "?"} 就绪（${payload.hotkeyLabel ?? payload.hotkey ?? "?"}）`,
            );
            continue;
          }
          if (payload?.event === "permission-required") {
            ctx.logger?.warn?.(
              "dsh-native-tools: 需要在「系统设置 › 隐私与安全性 › 屏幕录制」里勾选 DeepSeek Harness",
            );
            continue;
          }
        } catch {
          // helper 的普通日志行，原样转给 Host 日志即可。
        }
        ctx.logger?.info?.(`dsh-native-tools[helper]: ${trimmed}`);
      }
    });
    started.stderr?.setEncoding("utf8");
    started.stderr?.on("data", (chunk) => {
      const text = String(chunk).trim();
      if (text !== "") ctx.logger?.warn?.(`dsh-native-tools[helper]: ${text}`);
    });
    started.on("error", (error) => {
      ctx.logger?.warn?.(`dsh-native-tools: 原生进程启动失败: ${error.message}`);
    });
    started.on("exit", (code, signal) => {
      if (child === started) child = undefined;
      if (disposing) return;
      // 全部关掉时会话自己把这进程送走（quit），这不是崩溃，别退避重启。
      if (desired().length === 0) return;
      const delay = RESTART_STEPS_MS[Math.min(attempts, RESTART_STEPS_MS.length - 1)];
      attempts += 1;
      ctx.logger?.warn?.(`dsh-native-tools: 原生进程退出（${signal ?? code}），${delay}ms 后重启`);
      clearRestartTimer();
      restartTimer = setTimeout(async () => {
        restartTimer = undefined;
        if (disposing) return;
        let recovered = false;
        for (const feature of desired()) {
          recovered = (await adoptFeature(feature)) || recovered;
        }
        if (!recovered) startChild();
      }, delay);
      restartTimer.unref?.();
    });
  };

  // ---- 让进程对齐配置：启动、设置页改动、探活恢复都走这里 ------------------

  /**
   * 把最新配置推给一个已经接管的功能。helper 的 `adopt` 顺带 `applySettings`，
   * 所以「重发一次 adopt」就是通用的推设置手段：热键、目录、OCR、条数都跟着换。
   */
  const pushSettings = async (feature) => {
    const reply = await sendControl(
      { command: "adopt", parentPID: process.pid, generation, ...settingsFor(feature.slug) },
      { path: socketPathFor(feature), timeout: 1_500 },
    );
    if (reply?.ok === true) return true;
    // 推不进去说明这个功能已经不在了：从基准里摘掉，下一步按「未接管」重来。
    attached.delete(feature.slug);
    return false;
  };

  /** 全部关掉：让 helper 卸完最后一个功能后自己退出，别留个空进程。 */
  const retireIfIdle = async () => {
    stopHealthMonitor();
    translateHost?.close();
    translateHost = undefined;
    const remaining = (await sendControl({ command: "status" }))?.features?.length;
    if (remaining === 0) await sendControl({ command: "quit" });
    ctx.logger?.info?.("dsh-native-tools: 四个功能都关掉了，原生进程不保留");
  };

  /**
   * 配置里所有 volatile 字段的指纹。`loader/volatile-update` 是给整个 Host 派的，
   * 别的插件改设置也会收到，所以要先看是不是自己的字段动了。
   */
  const signatureOf = () => JSON.stringify([
    isOn("screenshot"), stringField("screenshot", "hotkey"), stringField("screenshot", "saveDirectory"),
    stringField("screenshot", "ocrLanguages"), field("screenshot", "ocrKeepLineBreaks"),
    isOn("clipboard"), stringField("clipboard", "hotkey"),
    field("clipboard", "maxItems"), field("clipboard", "retentionDays"),
    isOn("translate"), stringField("translate", "hotkey"),
    stringField("translate", "provider"), stringField("translate", "targetLanguage"),
  ]);
  let lastSignature = "";

  /**
   * 对齐一次：关掉的卸下、打开的接管、已接管的换上新设置、翻译通道跟着换。
   * 因为开关与热键都在 volatile 字段里，这一步在设置页里点完立刻跑，不重启插件。
   */
  const sync = async (force = false) => {
    if (disposing) return;
    const signature = signatureOf();
    if (!force && signature === lastSignature) return;
    lastSignature = signature;

    const wanted = desired();
    const wantedSlugs = new Set(wanted.map((feature) => feature.slug));

    // 关掉的：卸下（顺手注销热键、收面板）。已经卸过的不重复发。
    for (const feature of FEATURES) {
      if (wantedSlugs.has(feature.slug)) continue;
      if (attached.has(feature.slug) || !detached.has(feature.slug)) {
        const remaining = await detachFeature(feature);
        if (remaining === 0) stopHealthMonitor();
      }
    }

    syncTranslateHost();

    if (wanted.length === 0) {
      await retireIfIdle();
      return;
    }

    let adopted = false;
    for (const feature of wanted) {
      adopted = (attached.has(feature.slug)
        ? await pushSettings(feature)
        : await adoptFeature(feature)) || adopted;
    }
    if (adopted) {
      startHealthMonitor();
      return;
    }
    startChild();
  };

  /**
   * 串行化：连点几下开关会连发事件，排队跑，免得两次 sync 互相踩。
   */
  let syncChain = Promise.resolve();
  const queueSync = (force = false) => {
    syncChain = syncChain.then(() => sync(force)).catch((error) => {
      ctx.logger?.warn?.(`dsh-native-tools: 应用设置失败（${error?.message ?? String(error)}）`);
    });
    return syncChain;
  };

  void queueSync(true);

  /**
   * 设置页写的是 volatile 字段：Host 不重启插件，只更新引用然后派这个事件。
   * 这里重新读配置、把进程对齐过去，所以改设置是立刻生效的。
   */
  ctx.on("loader/volatile-update", () => void queueSync());

  ctx.on("dispose", () => {
    disposing = true;
    clearRestartTimer();
    stopHealthMonitor();
    translateHost?.close();
    const running = child;
    child = undefined;
    // 配置改动会先 dispose 再 apply 一份新实例。交接而不是杀掉：helper 收到 release
    // 后保留窗口与已注册的快捷键，5 秒内没人 adopt 才自己退出，所以改设置不会打断
    // 正在框选的截图，也不会在 DSH 退出后留下进程。
    void (async () => {
      let released = false;
      // 交接范围：接管过的 + 配置里还开着的（探活可能还没来得及重新接管）。
      for (const feature of FEATURES) {
        if (!attached.has(feature.slug) && !isOn(feature.slug)) continue;
        const reply = await sendControl({ command: "release", generation }, { path: socketPathFor(feature), timeout: 700 });
        // `ignored` 说明这个功能现在挂的是别人的代号（例如另一个插件实例），
        // 那就不算交接成功——不能再把进程当成自己的来杀。
        if (reply?.ok === true && reply.ignored !== true) released = true;
      }
      if (released || running === undefined) return;
      running.kill("SIGTERM");
      const killer = setTimeout(() => {
        if (running.exitCode === null && running.signalCode === null) running.kill("SIGKILL");
      }, 1_500);
      killer.unref?.();
    })();
  });
}
