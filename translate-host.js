/**
 * 翻译的 Host 半边（从 dsh-translate/index.js 原样搬过来，逻辑没动）。
 *
 * 职责：在 Unix socket 上等原生进程发来 `{"command":"translate","text":...}`，调
 * `ctx.translator` 翻完回包。原生进程只负责壳和键盘，翻译通道、模型、网络都在这一侧，
 * 所以换通道、换模型都不用动 Swift。
 */
import { createRequire } from "node:module";
import { chmodSync, mkdirSync, unlinkSync } from "node:fs";
import { connect, createServer } from "node:net";
import { dirname, join } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";

const PACKAGE_DIR = dirname(fileURLToPath(import.meta.url));

export const DEFAULT_PROVIDER = "bing";
export const DEFAULT_TARGET = "auto";
export const MAX_INPUT_CHARS = 50_000;
export const TRANSLATE_DEADLINE_MS = 90_000;

/**
 * `@deepseek-ai/dsh-experimental-translator` 的 Config 里 provider 是封闭联合类型
 * `['google','bing','deepseek-account','deepseek-official']`，写别的名字它连挂载都过不了
 * （Config 校验先失败，报错信息很难读）。这里先拦一道，给人能读懂的话。
 */
const KNOWN_PROVIDERS = ["bing", "google", "deepseek-account", "deepseek-official"];
/** 这两个要在一个活的 Session 里记账（译文写进会话日志），浮窗没有会话。 */
const SESSION_PROVIDERS = ["deepseek-account", "deepseek-official"];

/** 目前挂着的翻译服务；没有就是 undefined（此时浮窗里会明说原因）。 */
function currentTranslator(ctx) {
  const candidates = [];
  try {
    candidates.push(ctx.translator);
  } catch {
    // 服务缺席时读取属性可能抛错，忽略即可。
  }
  try {
    candidates.push(ctx.reflect?.get?.("translator", false));
  } catch {
    // 同上。
  }
  for (const candidate of candidates) {
    if (candidate !== null && typeof candidate === "object" && typeof candidate.translate === "function") {
      return candidate;
    }
  }
  return undefined;
}

/**
 * 确保 ctx.translator 存在。
 *
 * 优先复用已有的服务（用户装了官方「划词翻译」bundle 的情况）；
 * 没有时自己从安装目录把 @deepseek-ai/dsh-experimental-translator 挂上。
 * 直接用代码挂载而不是写进 cordis.patch.yml，是因为这样能拿到「挂不上」的确切
 * 原因并降级成一条人能读懂的提示，而不是整个插件的 patch 都加载失败。
 */
/**
 * 翻译服务入口文件在哪个 node_modules 里，取决于插件是被谁加载的：
 *   - 开发/自测时 DSH_INSTALL_DIR 指着安装目录；
 *   - 真实 DSH 里宿主入口是 app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js，
 *     从它往上数正好是装 @deepseek-ai/* 的那个 node_modules；
 *   - profile 里则要往 profile 的 node_modules 找。
 * 这几处都试一遍，比只赌一个环境变量稳。
 */
function translatorRequireBases() {
  const bases = [];
  const push = (base) => {
    if (typeof base === "string" && base !== "" && !bases.includes(base)) bases.push(base);
  };
  const install = process.env.DSH_INSTALL_DIR;
  if (install) push(join(install, "package.json"));
  if (typeof process.argv[1] === "string") push(process.argv[1]);
  const profile = process.env.DSH_PROFILE_DIR;
  if (profile) push(join(profile, "noop.cjs"));
  push(join(PACKAGE_DIR, "noop.cjs"));
  return bases;
}

/** 依次在候选基点里解析并加载翻译服务模块。 */
async function loadTranslatorModule() {
  const failures = [];
  for (const base of translatorRequireBases()) {
    try {
      const require = createRequire(base);
      const entry = require.resolve("@deepseek-ai/dsh-experimental-translator");
      const loaded = await import(pathToFileURL(entry).href);
      const Translator = loaded.default ?? loaded;
      if (Translator !== undefined && Translator !== null) {
        return { Translator, entry, base };
      }
      failures.push(`${base}: 模块导出是空的`);
    } catch (error) {
      failures.push(`${base}: ${error?.message ?? String(error)}`);
    }
  }
  return { error: failures.join(" | ") };
}

async function ensureTranslator(ctx, config) {
  const existing = currentTranslator(ctx);
  if (existing !== undefined) return { translator: existing, owned: false };

  const loadedModule = await loadTranslatorModule();
  const Translator = loadedModule.Translator;

  if (Translator === undefined) {
    const reason = `找不到 @deepseek-ai/dsh-experimental-translator（${loadedModule.error ?? "未知原因"}）`;
    ctx.logger?.warn?.(`dsh-translate: 加载翻译服务失败：${reason}`);
    return { translator: undefined, owned: false, reason };
  }
  ctx.logger?.info?.(`dsh-translate: 翻译服务模块来自 ${loadedModule.entry}`);

  try {
    ctx.plugin(Translator, { provider: config.provider });
  } catch (error) {
    const reason = `挂载翻译服务失败（${error?.message ?? String(error)}）`;
    ctx.logger?.warn?.(`dsh-translate: ${reason}`);
    return { translator: undefined, owned: false, reason };
  }

  // 服务在构造时注册，但仍等一小会，避免第一次按键抢在注册之前。
  const deadline = Date.now() + 3_000;
  while (Date.now() < deadline) {
    const translator = currentTranslator(ctx);
    if (translator !== undefined) return { translator, owned: true };
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const reason = "翻译服务已挂载，但 3 秒内仍未注册成 ctx.translator";
  ctx.logger?.warn?.(`dsh-translate: ${reason}`);
  return { translator: currentTranslator(ctx), owned: true, reason };
}

/** 中日韩统一表意文字：有就认为「中文输入」，译成英文。 */
const CJK = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/;

/** 按自动/指定规则算出这次要译成什么语言。 */
function resolveTarget(text, mode) {
  const wanted = typeof mode === "string" ? mode.trim() : "";
  if (wanted !== "" && wanted !== "auto") return wanted;
  return CJK.test(text) ? "en" : "zh-CN";
}

/**
 * 把超长文本切成不超过上限的片段。
 *
 * 优先在换行处断开（保留原文换行，拼回去时不用再加）；单段本身超长时按字符
 * 硬切，保证每一片都不触发 TRANSLATION_TEXT_LIMIT。
 */
function splitForProvider(text, limit) {
  const max = Number.isFinite(limit) && limit > 1 ? Math.floor(limit) : 4_000;
  if (text.length <= max) return [text];
  const chunks = [];
  let current = "";
  const flush = () => {
    if (current !== "") chunks.push(current);
    current = "";
  };
  for (const piece of text.split(/(?<=\n)/)) {
    if (piece.length > max) {
      flush();
      for (let index = 0; index < piece.length; index += max) {
        chunks.push(piece.slice(index, index + max));
      }
      continue;
    }
    if (current.length + piece.length > max) flush();
    current += piece;
  }
  flush();
  return chunks;
}

/** 把翻译层抛出的错误翻成人能读懂的一句话。 */
function describeError(error) {
  const code = typeof error?.code === "string" ? error.code : "";
  const message = typeof error?.message === "string" ? error.message : String(error);
  if (code === "TRANSLATION_TEXT_LIMIT") {
    return { code, error: "文本超过单次翻译上限，请分段后再试", detail: message };
  }
  if (code === "TRANSLATION_SESSION_REQUIRED") {
    return { code, error: "这条翻译通道需要登录状态，请改用 bing 或 google", detail: message };
  }
  if (error?.name === "AbortError" || /abort|timeout|timed out/i.test(message)) {
    return { code: "TRANSLATION_TIMEOUT", error: "翻译超时，检查网络或稍后重试", detail: message };
  }
  if (/fetch failed|ENOTFOUND|ECONNREFUSED|ECONNRESET|EAI_AGAIN|network/i.test(message)) {
    return { code: "TRANSLATION_NETWORK", error: "网络请求失败，检查网络或代理后再试", detail: message };
  }
  if (/40[0-9]|429|rate|limit/i.test(message)) {
    return { code: "TRANSLATION_THROTTLED", error: "翻译服务暂时拒绝或限流，稍后再试", detail: message };
  }
  return { code: code !== "" ? code : "TRANSLATION_FAILED", error: "翻译失败", detail: message };
}

/**
 * 通道名合法性检查；返回 null 表示这个通道能用在浮窗里。
 * 写错名字时要先说清楚，否则会掉进翻译层的 Config 校验，报一句没人看得懂的话。
 */
function providerProblem(provider) {
  if (!KNOWN_PROVIDERS.includes(provider)) {
    return {
      code: "TRANSLATION_PROVIDER_UNKNOWN",
      error: `没有这个翻译通道：${provider}（可选 ${KNOWN_PROVIDERS.slice(0, 2).join("、")}）`,
    };
  }
  if (SESSION_PROVIDERS.includes(provider)) {
    return {
      code: "TRANSLATION_SESSION_REQUIRED",
      error: `翻译通道 ${provider} 只能在对话里用（译文要记进会话），浮窗请改用 bing 或 google`,
    };
  }
  return null;
}

/** 真正干活的地方：分段、顺序翻译、拼回去。 */
async function translateRequest(translator, raw, { provider, targetLanguage, onProgress }) {
  const started = Date.now();
  const text = typeof raw === "string" ? raw : "";
  const target = resolveTarget(text, targetLanguage);
  if (text.trim() === "") return { ok: true, text: "", target, unchanged: true, chunks: 0 };
  const problem = providerProblem(provider);
  if (problem !== null) return { ok: false, ...problem };
  if (text.length > MAX_INPUT_CHARS) {
    return {
      ok: false,
      code: "TRANSLATION_TEXT_TOO_LONG",
      error: `一次最多 ${MAX_INPUT_CHARS} 个字符（当前 ${text.length}），请分段再译`,
    };
  }

  const chunks = splitForProvider(text, translator.maxTextChars ?? 4_000);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error("translate deadline")), TRANSLATE_DEADLINE_MS);
  timer.unref?.();
  const parts = [];
  try {
    for (const [index, chunk] of chunks.entries()) {
      const spec = translator.resolve({
        text: chunk,
        targetLanguage: target,
        sourceLanguage: "auto",
        provider,
      });
      const out = await translator.translate(spec, controller.signal);
      parts.push(typeof out === "string" ? out : "");
      // 分片越多，进度越值得回报；单片时 helper 只看「翻译中」。
      if (chunks.length > 1) {
        onProgress?.({ index: index + 1, total: chunks.length });
      }
    }
    return {
      ok: true,
      text: parts.join(""),
      target,
      provider,
      chunks: chunks.length,
      elapsedMs: Date.now() - started,
    };
  } catch (error) {
    return { ...describeError(error), ok: false };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 起翻译通道，并把「能不能翻」的原因一起返回。
 *
 * 返回的 `ready` promise 在翻译服务可用（或确认不可用）后 resolve；helper 那边
 * 不管它：真来请求时再检查，缺服务就回一条人能读懂的错误。
 */
export function startTranslateHost({ ctx, socketPath, provider, targetLanguage }) {
  const settings = {
    provider: provider ?? DEFAULT_PROVIDER,
    targetLanguage: targetLanguage ?? DEFAULT_TARGET,
  };
  let translator;
  let translatorIssue = "";
  let closing = false;

  mkdirSync(dirname(socketPath), { recursive: true });
  const server = createServer((socket) => {
    let buffer = "";
    let replied = false;
    socket.setEncoding("utf8");
    socket.setTimeout(TRANSLATE_DEADLINE_MS + 10_000, () => socket.destroy());
    const finish = (payload) => {
      if (replied) return;
      replied = true;
      try {
        socket.end(`${JSON.stringify(payload)}\n`);
      } catch {
        socket.destroy();
      }
    };
    const onProgress = (update) => {
      if (replied) return;
      try {
        socket.write(`${JSON.stringify({ event: "progress", ...update })}\n`);
      } catch {
        // 连接断了就不用再回报。
      }
    };
    socket.on("error", () => socket.destroy());
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (line === "") return;
      let request;
      try {
        request = JSON.parse(line);
      } catch {
        finish({ ok: false, code: "BAD_REQUEST", error: "请求不是合法的 JSON" });
        return;
      }
      if (request?.command !== "translate") {
        finish({ ok: false, code: "BAD_REQUEST", error: `未知命令 ${String(request?.command)}` });
        return;
      }
      if (translator === undefined) {
        const problem = providerProblem(settings.provider);
        if (problem !== null) {
          finish({ ok: false, ...problem });
          return;
        }
        finish({
          ok: false,
          code: "TRANSLATION_UNAVAILABLE",
          error: "翻译服务未启用：没能挂上翻译能力",
          detail: translatorIssue === "" ? undefined : translatorIssue,
        });
        return;
      }
      void translateRequest(translator, request.text, { ...settings, onProgress })
        .then((reply) => finish({ event: "done", ...reply }))
        .catch((error) => finish({ ...describeError(error), ok: false }));
    });
  });

  /**
   * 这条路径上是不是已经有一个活着的服务。
   *
   * EADDRINUSE 有两种完全不同的原因：上一个实例崩了留下残根（该清），或者另一个
   * 正常运行的 DSH（或一个跑测试的进程）正占着它（清了就是**拔掉别人的线**——
   * 对方还监听在已经没人能连到的 inode 上，翻译从此静默失败，直到它重启）。
   * 差别只有连一下才能看出来。
   */
  const probeAlive = (path) => new Promise((resolve) => {
    let settled = false;
    const socket = connect(path);
    const finish = (alive) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.destroy(); } catch { /* 已经断了 */ }
      resolve(alive);
    };
    const timer = setTimeout(() => finish(false), 300);
    timer.unref?.();
    socket.on("connect", () => finish(true));
    socket.on("error", () => finish(false));
  });

  /** 这个路径是不是真的由我们绑上的——只有自己人才能删自己的 socket。 */
  let owned = false;

  const listen = (attempt = 0) => {
    server.once("error", (error) => {
      if (closing) return;
      if (error?.code === "EADDRINUSE" && attempt === 0) {
        void probeAlive(socketPath).then((alive) => {
          if (alive) {
            ctx.logger?.warn?.(
              `dsh-native-tools: 翻译通道已由另一个进程占用（${socketPath}），本实例不接管、也不删它`,
            );
            return;
          }
          // 没人应答：上一个实例留下的残根，清掉重来一次。
          try {
            unlinkSync(socketPath);
          } catch {
            // 别人的 socket，删不掉就只能认输。
          }
          listen(1);
        });
        return;
      }
      ctx.logger?.warn?.(`dsh-native-tools: 翻译通道监听失败（${error.message}）`);
    });
    server.listen(socketPath, () => {
      owned = true;
      try {
        chmodSync(socketPath, 0o600);
      } catch {
        // 权限收紧失败不影响功能。
      }
      ctx.logger?.info?.(`dsh-native-tools: 翻译通道就绪（${socketPath}）`);
    });
  };
  listen();

  /**
   * 解析（或复用）翻译能力。设置页换了通道时这里会再跑一次，所以做成可复用的函数。
   */
  const resolveTranslator = async () => {
    const result = await ensureTranslator(ctx, { provider: settings.provider });
    translator = result.translator;
    translatorIssue = result.reason ?? "";
    if (translator !== undefined) {
      const limit = translator.maxTextChars ?? 4_000;
      ctx.logger?.info?.(
        `dsh-native-tools: 翻译服务就绪（${result.owned ? "已挂载" : "复用已有"}，`
          + `通道 ${settings.provider}，单次上限 ${limit} 字符）`,
      );
    }
    return translator;
  };
  let ready = resolveTranslator();

  /**
   * 热更新：设置页把通道或目标语言改了就地生效——不清 socket、不重启插件。
   * 目标语言每次请求现读（`{ ...settings, onProgress }`），通道变了才重新解析翻译能力。
   */
  const configure = (next = {}) => {
    const provider = typeof next.provider === "string" && next.provider !== "" ? next.provider : settings.provider;
    const targetLanguage = typeof next.targetLanguage === "string" && next.targetLanguage !== ""
      ? next.targetLanguage
      : settings.targetLanguage;
    const providerChanged = provider !== settings.provider;
    settings.provider = provider;
    settings.targetLanguage = targetLanguage;
    if (!providerChanged || closing) return ready;
    translator = undefined;
    translatorIssue = "";
    ready = resolveTranslator();
    return ready;
  };

  return {
    path: socketPath,
    get ready() {
      return ready;
    },
    configure,
    close() {
      closing = true;
      try {
        server.close();
      } catch {
        // 已关闭。
      }
      // 只删自己绑上的那个：抢不到 EADDRINUSE 时删的会是别人的 socket。
      if (!owned) return;
      try {
        unlinkSync(socketPath);
      } catch {
        // 没有残留就不用删。
      }
      owned = false;
    },
  };
}
