/**
 * 通道名校验的隔离测试：给 startTranslateHost 塞一个假的 ctx.translator，
 * 这样不用真的挂载 DSH 翻译服务，也能验到「请求进来到回包」这段管道。
 *
 * 覆盖：未知通道名、只能在对话里用的通道、正常通道。
 * 用法：node host-test/provider-cases.mjs（不需要 helper，也不碰任何真实 socket）
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect } from "node:net";
import { startTranslateHost } from "../translate-host.js";

const root = mkdtempSync(join(tmpdir(), "provider-test-"));
const socketPath = join(root, "host.sock");

/** 假的翻译服务：resolve 返回现成 spec，translate 原样回一句，方便看清走没走到这一步。 */
const fakeTranslator = {
  maxTextChars: 4000,
  resolve(request) {
    return { ...request, provider: request.provider ?? "bing", sourceLanguage: "auto" };
  },
  async translate(spec) {
    return `[${spec.provider}] ${spec.text}`;
  },
};

function ask(payload) {
  return new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    let buffer = "";
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("timeout"));
    }, 5000);
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(`${JSON.stringify(payload)}\n`));
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      clearTimeout(timer);
      socket.end();
      resolve(JSON.parse(buffer.slice(0, newline)));
    });
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

const host = startTranslateHost({ ctx: { translator: fakeTranslator }, socketPath, provider: "bing", targetLanguage: "auto" });
await host.ready;

const cases = [
  { name: "正常通道 bing", provider: "bing", expect: (r) => r.ok === true },
  { name: "正常通道 google", provider: "google", expect: (r) => r.ok === true },
  { name: "未知通道名", provider: "youdao", expect: (r) => r.code === "TRANSLATION_PROVIDER_UNKNOWN" },
  { name: "会话专用 deepseek-account", provider: "deepseek-account", expect: (r) => r.code === "TRANSLATION_SESSION_REQUIRED" },
  { name: "会话专用 deepseek-official", provider: "deepseek-official", expect: (r) => r.code === "TRANSLATION_SESSION_REQUIRED" },
];

let failures = 0;
for (const item of cases) {
  host.configure({ provider: item.provider });
  await host.ready;
  const reply = await ask({ command: "translate", text: "hello", targetLanguage: "zh" });
  const passed = item.expect(reply);
  if (!passed) failures += 1;
  console.log(`${passed ? "PASS" : "FAIL"} ${item.name} → ${JSON.stringify(reply)}`);
}

host.close();
rmSync(root, { recursive: true, force: true });
console.log(failures === 0 ? `全部通过（${cases.length} 项）` : `${failures} 项失败`);
process.exit(failures === 0 ? 0 : 1);
