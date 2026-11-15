# Host 半边的热更新自测

`index.js` 现在的行为是「改设置 = 热更新」：不重启插件，不重拉原生进程，拨一个开关只调整那一个功能。这一点没法靠 Swift 自测覆盖（自测只管到 helper 里面），所以单独放在这里。

三个脚本都是**隔离运行**的：自己在临时目录里造一套 home 与 socket 路径，跑完就退出；`provider-cases.mjs` 连 helper 都不需要（用假的翻译服务验管道）。

```bash
NODE=~/…/node          # 系统 PATH 里没有 node；本机是
                      # ~/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin/node
cd …/dsh-native-tools
$NODE host-test/live-toggle.mjs     # 改普通设置要热生效
$NODE host-test/live-switch.mjs     # 开关与热键的组合变化
$NODE host-test/provider-cases.mjs  # 翻译通道名的校验与报错文案
```

## live-toggle.mjs

1. 只开剪贴板 → 自动拉起 helper 并接管；
2. 把 `maxItems` 从 50 改成 20 → 同一 pid 上热生效；
3. 关掉剪贴板 → 卸下、进程自己退出（约 150 ms）。

## live-switch.mjs

1. 三个都关着启动 → 不拉起任何进程；
2. 全关状态下打开剪贴板 → 自己 spawn；
3. 改热键 `cmd+shift+v` → `cmd+shift+y` → 同一 pid 上热生效；
4. 关剪贴板、开翻译 → 同一个 helper 里换功能（翻译通道随之起来）；
5. 全关 → 进程退出。

## provider-cases.mjs

给 `startTranslateHost()` 塞一个假的 `ctx.translator`（所以不用真的挂载 DSH 翻译服务，也不联网），
按 `host.sock` 协议发 `{"command":"translate"}`，验五个通道名：`bing` / `google` 正常回包，
`youdao` 回 `TRANSLATION_PROVIDER_UNKNOWN`，`deepseek-account` / `deepseek-official` 回
`TRANSLATION_SESSION_REQUIRED`（原因见 HANDOFF 坑 17）。

## 两个坑

- **`socket.setTimeout()` 的定时器是 unref 的**。等 socket 回包的 promise 如果只靠它兜底，event loop 会判定「没事可做」而退出，表现是 `Warning: Detected unsettled top-level await` + exit code 13。脚本里统一用真 `setTimeout` + `clearTimeout`。
- **`DSHS_TRANSLATE_HOST_SOCKET` 必须设成临时路径**。翻译通道的 socket 路径默认是 `~/Library/Application Support/DSHTranslate/host.sock`，也就是**真正在跑的那个 DSH** 用的路径；测试去绑它就会撞上 `EADDRINUSE`。`translate-host.js` 现在会先探活再决定是否清理残根（见 HANDOFF 坑 16），但测试仍然应该自己用一个路径，别去碰正在跑的那个。
