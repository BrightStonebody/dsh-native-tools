/**
 * Host 半边（index.js）的热更新冒烟测试之一：改设置 → 立刻生效。
 *
 * 全程在临时目录里跑（临时 home + 临时 socket），用临时目录启动自己的 helper，
 * **不碰** 用户正在用的那个进程和它的历史记录。跑完临时目录可以随手删。
 *
 *   node host-test/live-toggle.mjs
 *
 * 覆盖的路径：
 *   1. 从零 spawn helper 并接管一个功能；
 *   2. 改普通设置（maxItems）→ 热更新，进程不重启；
 *   3. 关掉唯一的功能 → 卸下、进程自己退出。
 */
import { connect } from "node:net";
import { mkdtempSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const packageDir = dirname(here);
const root = mkdtempSync(join(tmpdir(), "dsh-native-tools-live-"));

const sockets = {
  screenshot: join(root, "DSHScreenshot", "control.sock"),
  clipboard: join(root, "DSHClipboard", "control.sock"),
  translate: join(root, "DSHTranslate", "control.sock"),
  native: join(root, "DSHNative", "control.sock"),
};

Object.assign(process.env, {
  DSHS_NATIVE_HOME: join(root, "DSHNative"),
  DSHS_NATIVE_SOCKET: sockets.native,
  DSHS_SCREENSHOT_SOCKET: sockets.screenshot,
  DSHS_CLIPBOARD_SOCKET: sockets.clipboard,
  DSHS_CLIPBOARD_HOME: join(root, "DSHClipboard"),
  DSHS_TRANSLATE_SOCKET: sockets.translate,
  DSHS_TRANSLATE_HOME: join(root, "DSHTranslate"),
  DSHS_TRANSLATE_HOST_SOCKET: join(root, "DSHTranslate", "host.sock"),
  DSH_PROFILE_DIR: process.env.DSH_PROFILE_DIR ?? join(homedir(), ".dsh/profiles/desktop"),
});

/** 设置页写 volatile 字段用的就是这把钥匙（cosmokit 的写符号）。 */
const WRITE = Symbol.for("cosmokit.volatile.write");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * 问一次控制通道。超时用真正的 setTimeout —— `socket.setTimeout` 的定时器是 unref 的，
 * 进程可能在等它的路上就被判定「没事可做」而退出。
 */
function ask(path, payload, timeout = 1_200) {
  return new Promise((resolve) => {
    const socket = connect(path);
    let buffer = "";
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { socket.destroy(); } catch { /* 已经断了 */ }
      resolve(value);
    };
    const timer = setTimeout(() => finish(undefined), timeout);
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(`${JSON.stringify(payload)}\n`));
    socket.on("error", () => finish(undefined));
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      try { finish(JSON.parse(buffer.slice(0, newline))); } catch { finish(undefined); }
    });
  });
}

async function waitFor(label, predicate, timeout = 15_000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    const value = await predicate();
    if (value) return value;
    await sleep(120);
  }
  throw new Error(`等待超时：${label}`);
}

const logs = [];
const listeners = [];
const ctx = {
  logger: { info: (line) => logs.push(`info ${line}`), warn: (line) => logs.push(`warn ${line}`) },
  on(event, handler) { listeners.push({ event, handler }); },
  effect() { return () => {}; },
  inject() { return () => {}; },
};
const fire = (event) => listeners.filter((l) => l.event === event).forEach((l) => l.handler());

const module = await import(`file://${join(packageDir, "index.js")}`);

// 只开剪贴板：最小干扰面，不碰屏幕录制权限。
const config = module.Config({
  screenshot: { enabled: false },
  clipboard: { enabled: true, maxItems: 50, retentionDays: 7 },
  translate: { enabled: false },
});

module.apply(ctx, config);

const clipboardStatus = () => ask(sockets.clipboard, { command: "status" });
const nativeStatus = () => ask(sockets.native, { command: "status" });

console.log("1) 等 helper 起来并接管剪贴板…");
const first = await waitFor("剪贴板接管成功", () => clipboardStatus().then(
  (reply) => (reply?.ok === true && reply.attached === true ? reply : undefined),
));
console.log("   ok:", JSON.stringify({ pid: first.pid, hotkey: first.hotkey, maxItems: first.maxItems }));

console.log("2) 把 maxItems 改成 20 并派发 loader/volatile-update…");
config.clipboard.maxItems[WRITE](20);
fire("loader/volatile-update");
const second = await waitFor("maxItems 变成 20", () => clipboardStatus().then(
  (reply) => (reply?.maxItems === 20 ? reply : undefined),
));
console.log("   ok: maxItems =", second.maxItems, "pid 没变:", second.pid === first.pid);

console.log("3) 关掉剪贴板开关…");
const startedExit = Date.now();
config.clipboard.enabled[WRITE](false);
fire("loader/volatile-update");
await waitFor("helper 退出", async () => {
  const native = await nativeStatus();
  const clipboard = await clipboardStatus();
  return native === undefined && clipboard === undefined;
});
console.log("   进程已退出，用时", Date.now() - startedExit, "ms");

fire("dispose");
await sleep(300);
console.log("\n通过 ✅");
for (const line of logs.filter((l) => /卸下|接管|就绪|关掉/.test(l))) console.log("  " + line);
process.exit(0);
