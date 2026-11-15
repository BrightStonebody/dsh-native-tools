/**
 * Host 半边的热更新冒烟测试之二：开关与热键的组合变化。
 *
 *   node host-test/live-switch.mjs
 *
 * 覆盖的路径（每一步都不重启插件、不复位进程）：
 *   1. 三个都关着启动 → 不拉进程；
 *   2. 全关状态下打开剪贴板 → 自己 spawn；
 *   3. 改热键 → 同一进程上热生效；
 *   4. 关剪贴板、开翻译 → 同一个 helper 里换功能；
 *   5. 最后全关 → 进程退出。
 */
import { connect } from "node:net";
import { mkdtempSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const packageDir = dirname(here);
const root = mkdtempSync(join(tmpdir(), "dsh-native-tools-live-switch-"));

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

const WRITE = Symbol.for("cosmokit.volatile.write");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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

async function waitFor(label, predicate, timeout = 20_000) {
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
const config = module.Config({
  screenshot: { enabled: false },
  clipboard: { enabled: false },
  translate: { enabled: false },
});

console.log("1) 三个都关着启动：不该拉起任何进程");
module.apply(ctx, config);
await sleep(1_500);
const idle = await ask(sockets.native, { command: "status" });
console.log("   ", idle === undefined ? "没有进程 ✅" : "有进程（意外）");

console.log("2) 全关状态下打开剪贴板（要自己 spawn）…");
config.clipboard.enabled[WRITE](true);
fire("loader/volatile-update");
const spawned = await waitFor("剪贴板接管成功", () => ask(sockets.clipboard, { command: "status" }).then(
  (reply) => (reply?.ok === true && reply.attached === true ? reply : undefined),
));
console.log("   ok: pid", spawned.pid, "hotkey", spawned.hotkey);

console.log("3) 改热键 cmd+shift+y…");
config.clipboard.hotkey[WRITE]("cmd+shift+y");
fire("loader/volatile-update");
const hot = await waitFor("热键生效", () => ask(sockets.clipboard, { command: "status" }).then(
  (reply) => (reply?.hotkey === "cmd+shift+y" ? reply : undefined),
));
console.log("   ok: hotkey =", hot.hotkey, "同 pid:", hot.pid === spawned.pid);

console.log("4) 关剪贴板、开翻译：同一个进程里换功能");
config.translate.enabled[WRITE](true);
config.clipboard.enabled[WRITE](false);
fire("loader/volatile-update");
const swapped = await waitFor("剪贴板卸下、翻译接管", async () => {
  const clipboard = await ask(sockets.clipboard, { command: "status" });
  if (clipboard !== undefined) return undefined;      // 剪贴板的 socket 应该已经没了
  const translate = await ask(sockets.translate, { command: "status" });
  return translate?.ok === true && translate.attached === true ? translate : undefined;
});
console.log("   ok: 翻译 pid", swapped.pid, "（和剪贴板同一个进程:", swapped.pid === spawned.pid, "）");

console.log("5) 收尾：全关");
config.translate.enabled[WRITE](false);
fire("loader/volatile-update");
await waitFor("进程退出", async () => (await ask(sockets.native, { command: "status" })) === undefined);
console.log("   进程已退出 ✅");

fire("dispose");
await sleep(300);
console.log("\n通过 ✅");
for (const line of logs.filter((l) => /卸下|接管|就绪|关掉|加入/.test(l))) console.log("  " + line);
process.exit(0);
