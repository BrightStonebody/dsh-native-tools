# 交接摘要（HANDOFF）

> 新会话开场只要说一句「读 `dsh-native-tools/HANDOFF.md`」，再讲要做什么，就能接上。
> 这份文件写于 2026-11-15 14:35（Asia/Shanghai），内容是**当时**的现场状态；凡带「待」的地方都还没做完。

## 一句话现状

三个原本各自独立、各自一个原生进程的插件（截图 / 剪贴板历史 / 翻译），已经合并成**一个插件包 + 一个原生进程**：包名 `dsh-native-tools` 2.0.0，安装方式是 profile 里的 `link:`；原生侧是 `helper/DSHNative.app`（通用二进制），一个进程里同时跑三个 feature，各自保留原来的控制 socket 与配置目录。

## 目录与职责

```
default-workspace/dsh-native-tools/
├── package.json          dsh-native-tools 2.0.0；dsh.bundle.patch → cordis.patch.yml；dsh.client → client.js
├── cordis.patch.yml      insert 行 id `dsh-native-tools`，config: {}（默认值由 schemastery schema 给）
├── index.js              Host 半边：Config schema、spawn/adopt/detach、5s 探活、翻译请求服务端
├── translate-host.js     翻译的 Host 半边（从旧 dsh-translate/index.js 抽出来的模块）
├── client.js             客户端半边：插件页里的设置页（三张卡 + 三个开关），注册两个槽
├── locale/{zh,en}.json   插件名「原生助手」/ "Native Helper" 与简介
├── icon.svg              三功能合一的图标
├── install.sh            去 quarantine + 重签 helper（分发到别的机器时跑）
├── engine/
│   ├── build.sh          唯一构建入口：arm64 + x86_64 → lipo → 装进 helper → 重签
│   └── Sources/NativeKit/
│       ├── Core/         Support(Log/printJSON/Output) · HotKey(多通道) · Control(参数化 socket)
│       │                 NativeFeature(协议+FeatureContext) · NativeHost(生命周期+共享通道)
│       │                 ScreenshotSettings / ClipboardSettings / TranslateSettings
│       ├── Features/Screenshot/  Capture OCR OCRPanel Overlay Renderer Toolbar
│       │                         ScreenshotSelfTest ScreenshotFeature
│       ├── Features/Clipboard/   Panel Pasteboard Store ClipboardSettings
│       │                         ClipboardSelfTest ClipboardFeature
│       ├── Features/Translate/   TranslateClient TranslatePanel TranslateSettings
│       │                         TranslateSelfTest TranslateFeature
│       └── main.swift    入口：--status / --self-test / join 三步 / 起 NSApplication
├── helper/DSHNative.app  产物：Contents/MacOS/DSHNative（通用二进制，2.0 MB 左右）
├── docs/                 四张界面截图（toolbar / ocr-panel / clipboard-panel / translate-panel）
├── dist/dsh-native-tools-2.0.0.zip   唯一分发包（1.2 MB，含 README 与上面这些）
└── README.md             面向使用者的文档：功能、配置、构建、自测、分发、排查
```

Swift 代码约 7.5k 行。旧的三份独立引擎还在 `dsh-screenshot/engine`、`dsh-clipboard/engine`、`dsh-translate/engine` 里，仅作考古；三个包的 `helper/` 已改名 `helper.retired/`（旧插件 fiber 只要还能 spawn 到旧路径就会续命，改名是当时唯一可靠的阻断办法）。

## 运行拓扑

- Host（DSH Node 进程）里只有 `index.js`；它 spawn 一次 `helper/DSHNative.app/Contents/MacOS/DSHNative`，参数形如
  `--feature screenshot --feature clipboard --feature translate --parent-pid <host pid> --host-socket ~/Library/Application Support/DSHTranslate/host.sock`。
- 第二个及之后的插件实例不会起第二个进程：join 三步 = ①向自己的 feature socket 发 `adopt` → ②不行就向共享通道发 `{"command":"adopt","feature":…,"socket":…}` → ③都不行才 spawn；抢不到 socket 的新进程打印 `already-running` 直接退出。
- 每 feature 独立 `generation` / `attached`；`release` 只认同一个代号（比对前 8 位，因为通道只露前缀），代号对不上回 `{"ok":true,"ignored":true}`；全部 detached 且没有 supervisor 时进程自己在 5 秒后退出。
- 每个插件实例每 5 秒探活（`status`，超时 800ms），连续两次失败就重新 adopt 或拉起。**只通过 socket 接管的那一方，没有 child 进程可监听 exit，全靠这条探活自愈。**

## 控制通道（调试时最有用）

- 每 feature 独立 socket：`~/Library/Application Support/DSHScreenshot/control.sock`、`…/DSHClipboard/control.sock`、`…/DSHTranslate/control.sock`；共享通道 `~/Library/Application Support/DSHNative/control.sock`。
- 环境变量可整体搬走（做隔离实验用）：`DSHS_NATIVE_HOME`、`DSHS_NATIVE_SOCKET`、`DSHS_SCREENSHOT_SOCKET`、`DSHS_SCREENSHOT_CONFIG_DIR`、`DSHS_CLIPBOARD_SOCKET`、`DSHS_CLIPBOARD_HOME`、`DSHS_TRANSLATE_SOCKET`、`DSHS_TRANSLATE_HOME`、`DSHS_TRANSLATE_HOST_SOCKET`。
- 常用命令（一行 JSON + `\n`，回一行 JSON）：
  - 通用：`status`、`adopt`、`release`、`quit`
  - 截图：`capture`、`select {rect:[x,y,w,h]}`、`confirm`、`save-to {path}`、`ocr`、`ocr-panel`、`copy-text`、`ocr-settings`、`snapshot {path}`（调试钩子，会先夺回 first responder 再取像素）
  - 剪贴板：`show`/`hide`/`toggle`/`configure`/`clear`/`delete`/`copy`/`snapshot`/`select`
  - 翻译：`show`/`hide`/`translate {text}`、`configure`
- 命令行探针：`helper/DSHNative.app/Contents/MacOS/DSHNative --status` 会逐个 feature 查一遍并合并打印。

## 构建 / 自测 / 安装

```bash
cd …/default-workspace/dsh-native-tools

# 构建（arm64 + x86_64 → lipo → 装进 helper → 重签）。唯一入口，别再手敲 swiftc。
./engine/build.sh

# 三段自测（都应在 failures 0）
DSHS_SELFTEST_DIR=/tmp/st  ./helper/DSHNative.app/Contents/MacOS/DSHNative --self-test --feature screenshot
DSHS_CLIPBOARD_HOME=/tmp/cb ./helper/DSHNative.app/Contents/MacOS/DSHNative --self-test --feature clipboard
DSHS_TRANSLATE_HOME=/tmp/tr ./helper/DSHNative.app/Contents/MacOS/DSHNative --self-test --feature translate

# 打包（dist/dsh-native-tools-<版本>.zip，版本号取自 package.json；会校验通用二进制）
./pack.sh

# Host 半边（改设置=热更新）的两段自测，见 host-test/README.md
NODE=/Users/a1/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin/node   # 系统 PATH 里没有 node
$NODE host-test/live-toggle.mjs    # maxItems 热生效、关掉后进程退出
$NODE host-test/live-switch.mjs    # 三段全关不拉进程、按需 spawn、改热键、同进程换功能
```

当前基线：screenshot 20 项、clipboard 55 项、translate 11 项、monitor 58 项，全过；helper md5 `cc21d5547f3c91620f3e8fd5e5982824`，`lipo -archs` = `x86_64 arm64`。

安装（本机）：`plugin_manager install_bundle`，target 用 `link:/Users/a1/Documents/deepseek-harness/default-workspace/dsh-native-tools`。装好后 entryId 是 `include:dsh-native-tools`（`list_plugins` 要 offset=200 才看得到，总数 238）。

## 踩过的坑（都还在生效，别重复踩）

1. **改 `client.js` / `index.js` 源码后必须重启 DSH**，只刷新页面不够：loader 用 `tree.import(name)` 按 Node 的模块缓存装载（`cordis-plugin-loader/src/config/entry.ts` 的 `_init()`），进程不重启就还是旧代码；`client.js` 更是在 Host 启动时被读进内存。注意这条**只针对改代码**——改设置（volatile 字段）现在是热更新，见坑 12。
2. **设置页要注册两个槽**：`plugins.bundle.config`（key = 包名 `dsh-native-tools`）与 `plugins.row.config`（key = `dsh-native-tools#dsh-native-tools`）。只注册后者时，插件详情页认为「这个插件没有配置」，开关就无处显示；bundle 槽的 owner 只给 `{view:'page'}`、**不给 `form`**，所以 `BundleConfigBridge` 自己去 `ctx.configForms.get('dsh-native-tools')` 取控制器并订阅快照。
3. **helper 写 stdout/stderr 不能用 `FileHandle`**：插件那侧管道一关，`-[NSConcreteFileHandle writeData:]` 抛 ObjC 异常 → `SIGABRT`（有过三份崩溃报告）。必须走 `Core/Support.swift` 的 `Output.write(_:to:)`（内部 `Darwin.write`，EPIPE 直接丢行）。只加 `signal(SIGPIPE, SIG_IGN)` 不够。
4. **`write` 会被同作用域的 `Output.write` 遮蔽**，编译报 `use of 'write' refers to instance method`；写 `Darwin.write(...)`。
5. **局部变量别叫 `type`**：会遮蔽 `Swift.type(of:)`，报 `incorrect argument label in call (have 'of:', expected 'context:')`。同理 `let targetType = NativeHost.featureType(forSlug:)`。
6. **两个 feature 不能有同名源文件**（都叫 `SelfTest.swift` 会让 swiftc 报 `filename "SelfTest.swift" used twice`）→ 现在是 `ScreenshotSelfTest.swift` / `ClipboardSelfTest.swift` / `TranslateSelfTest.swift`。
7. **bash 里 `$APP（…）` 会把全角括号前当成变量名**（`APP�: unbound variable`）→ 用 `${APP}`。
8. **屏幕录制的 TCC 授权记在责任进程 `DeepSeek Harness` 名下**（tccd 日志里 `responsible={identifier=com.deepseek.dsh}`），所以重编、重签 helper 都不会丢授权；换机器要重新勾一次「屏幕录制」。
9. **Rosetta 下 Vision 文字识别不可用**（`arch -x86_64` 跑 `VNImageRequestHandler.perform` 回 `nilError`）——这是 Rosetta 的限制，Intel 真机上是原生执行，但**未实测**。
10. **`debugSnapshot` 遇到活跃 field editor 会崩**：`cacheDisplay` 前先 `makeFirstResponder(view)`。
11. **全关三个功能时进程会退出**：`detach` 之后如果 `status.features` 为空就发 `quit`，这是设计行为；别把它当成崩溃。
12. **Config 里的叶子字段必须 `.volatile()`，否则设置页永远说「这个插件没有声明可配置项」**（2026-11-15 定位）。`dsh-settings/src/index.ts` 的 `describe()` 用 `volatileForm(schema)` 过滤，而 `dsh-settings/src/schema.ts` 的 `volatileForm()` 只保留 volatile 字段，一个都没有就返回 `undefined` → 该条目根本不进 settings 命名空间 → 客户端 `configForms.get('dsh-native-tools')` 的 `status` 恒为 `'unavailable'`。命名空间名是**profile 行 id**（`ns: entry.options.id`，即 `dsh-native-tools`），不是 loader entry id `include:dsh-native-tools`。这也是开关/热键能热更新的前提。
13. **运行时读 volatile 字段要 `.get()`**：`apply(ctx, config)` 拿到的 `config.screenshot.enabled` 是 `{ get() }` 引用（cosmokit `createVolatile`，写入用 `Symbol.for('cosmokit.volatile.write')`，没有 subscribe）。`index.js` 顶部有 `val()`/`field()`/`stringField()`，全文件都走它们；`enabled`/`disabled` 那种 apply 时算一次的数组是错的，要现算 `desired()`。
14. **`ctx.on('loader/volatile-update', …)` 是唯一的变更通知**，由 `Entry._commitVolatile()` 只派给**本条目自己的 fiber**（别的插件改设置收不到），携带变更过的 paths。`index.js` 的 `sync()` 收到后重新读配置、把进程对齐（卸下关掉的、接管打开的、给已接管的推新设置、换翻译通道），并发事件由 `syncChain` 串行化；`signatureOf()` 兜住「同值重复派发」。
15. **`translate-host.js` 的 `settings` 原本闭包在 `startTranslateHost()` 里**，改 provider 不会生效；已加 `configure({provider,targetLanguage})`（会重新 `ensureTranslator`，目标语言每次请求现读）。
16. **翻译通道的 socket 不能见 `EADDRINUSE` 就删**：那是「上一个实例的残根」还是「另一个活着的 DSH 正占着」，只有连一下才知道。早先的代码直接 `unlinkSync` 再重听，撞上第二种情况就是**拔掉别人的线**——对方还监听在已经没人能连到的 inode 上，翻译从此静默失败直到它重启（我们踩过一次：跑测试用了默认路径，把正在跑的 DSH 的 `host.sock` 删了）。现在 `translate-host.js` 先 `probeAlive()`，有人应答就警告并放弃；`owned` 为真才在 `close()` 里删自己的 socket。**跑任何测试都要把 `DSHS_TRANSLATE_HOST_SOCKET` 指向临时目录。**

17. **翻译通道只有 `bing` / `google` 能用在浮窗里**：`@deepseek-ai/dsh-experimental-translator` 的 Config 联合类型是 `['google','bing','deepseek-account','deepseek-official']`（`src/index.ts:57`），但后两个是付费通道，`resolve()` 要求 `request.sessionId`，`TranslationStorage.run()` 还要 `sessionPersistence` 与一个活着的 Session 才能把译文记进会话日志（`storage.ts:77-84`）——全局快捷键弹出来的浮窗没有会话，所以它们必然抛 `TRANSLATION_SESSION_REQUIRED`。**这台机器的 profile 默认模型就是 `deepseek-account` / `deepseek-flash`，所以别以为「账号登着就能用」**。`translate-host.js` 里 `providerProblem()` 先拦一道：写错名字回 `TRANSLATION_PROVIDER_UNKNOWN`、写会话专用通道回 `TRANSLATION_SESSION_REQUIRED`，都在挂载翻译服务之前返回，避免变成一句没人看得懂的 Config 校验错误。client.js 的通道字段是下拉框（两个可选 + 两个禁用并写明原因）。

18. **毛玻璃底板的圆角只能用 `maskImage`**（剪贴板面板，2026-11-15 用户报「大的背景圆角不是透明的，有白色背景色」）：在 `NSVisualEffectView`（`blendingMode = .behindWindow`）上设 `layer.cornerRadius` + `masksToBounds` 会把窗口服务器那张模糊底图裁掉，底板退化成一块不透明白色。正确做法是 `effect.maskImage = 九宫格圆角蒙版`（`ClipboardPanelController.roundedMask(radius:)`，`capInsets` = 半径、`resizingMode = .stretch`），图层上什么圆角都别设。自测 `panel-material` / `panel-mask-image` / `panel-no-layer-clip` 三项盯着这个，改回去立刻红。

19. **菜单栏三条是「上标签 / 下数字」的两行自绘 template 图，不是标题**（系统监控，2026-11-16）：`NSStatusItem` 的 `attributedTitle` 换行会被压成一行或直接裁掉，所以 `MonitorMenuBar.image(top:bottom:)` 用 `NSImage(size:flipped:drawingHandler:)` 自己画两行（上一行 9 号标签/箭头，下一行 12.5 号等宽粗体数字），`isTemplate = true` 跟菜单栏明暗自动反色。**画布宽度按「最坏样本」钉死**（`menuWidthSample`）：CPU/内存 `100%`，网络 `↓1023B`/`↑1023B` —— 最宽的不是 `999M` 而是四位数字的 B（`compactRate` 在 1024 以下给整数 B，加上箭头共 6 字）。文案在 `0B`/`512B`/`9.5K`/`999M` 之间跳时画布不变，菜单栏不抖。左右内边距**不要自己钉 `item.length`**：早先为了防抖把 `item.length` 设成最坏宽度，图比 item 窄、系统把图居中，多出来的空白被当成「边距比别的图标大」（用户报过两次：先是「为什么这三个边距不一样」，后是「网络状态变化时抖动很厉害」）—— 正确做法是 `variableLength`（系统按统一规则加内边距）+ 固定**图片**宽度。防漂移的责任在面板锚点（见坑 20）。另外空间不足时 macOS 会把最左边的第三方项收进 `«`（不是 bug），`--status` 的 `itemFrames` 看 x/宽度、`itemMetrics` 看 imageWidth/buttonWidth。

20. **面板漂移的两个来源：popover 尺寸每拍重设 + 锚在会变的按钮上**（系统监控）：① 高度要用「固定槽位」算 —— `MonitorPanelView.slotCount` 决定 `contentHeight`（`headerHeight + slotCount*rowHeight + footerHeight`），行数不足就留空；`resize()` 里还要 `guard popover.contentSize != size`，否则每拍设一次 contentSize 都会让 popover 重排一次。② **锚点不能是 `NSStatusBarButton`**：它的宽度会随数字位数变，邻居 App 的数字跳动也会把它挤动，`popover.show(relativeTo: button...)` 就会跟着挪。`MonitorPanelController` 现在用一个 1×1 透明无边框窗口（`level = .statusBar`、`ignoresMouseEvents`、`[.canJoinAllSpaces, .stationary]`）当锚点：显示时把它钉在按钮**当时的屏幕矩形**（`button.convert(button.bounds, to: nil)` → `window.convertToScreen`），然后 `show(relativeTo: anchorView.bounds, of: anchorView, …)`，`hide()` 里 `orderOut`。实测网络项宽度在 46–59pt 之间反复变，`panelFrame` 20 秒恒为同一个坐标。另外**箭头区会吃掉 contentSize 的一条边**（`preferredEdge: .minY` 时在顶部），内容被整体下推约 20pt，最后一行（页脚）会贴到边外被裁 —— `popoverSlack = 22` 补偿。

21. **进程名有三个来源，各有短板，必须合并**：`proc_name()` 只有 32 字节（`DeepSeek Harness Helper (Render`）、`nettop` 只给 15 个字符（`DeepSeek Harnes`）、`ps -A -o comm=` 是完整路径（取 lastPathComponent 才好看但最全）。`MonitorSampler` 的策略是：rusage 名做底 → ps 名更长就覆盖 → nettop 行用 `resolveNames()` 按 pid 换成 ps 全名 → 空名回退 `pid <n>`。另外**无 root 时 `proc_pid_rusage` 拿不到 root 进程**（本机 456 个 pid 里 178 个失败，`WindowServer` 就在其中），所以 CPU/内存榜必须用 `ps -A -o pid=,pcpu=,rss=,comm=` 兜底；`pcpu` 是内核衰减平均，别拿它当瞬时值去和 rusage 差分比大小。

22. **进程的 App 图标只给「真的归属某个 App」的进程**（系统监控）：两步 —— ① `NSRunningApplication(processIdentifier:)` 且 `bundleIdentifier != nil` 才用它的 `icon`（不带 bundle 的命令行工具也会造出「通用 App」，那个通用图标就是用户看到的空白方块）；② 否则看可执行文件是否落在某个 `.app/Contents/…` 里，是就用那个 App 的图标 —— Chrome / DSH 的 Renderer、GPU 这些 helper 在 LaunchServices 里没有身份（实测一部分 `bid=nil`），全靠这条兜底。**不要直接对可执行文件取 `NSWorkspace.icon(forFile:)` 当兜底**：守护进程（WindowServer、powermetrics、sysmond、airportd）拿到的是通用空白方块，16px 下像加载失败。另两点：`PROC_PIDPATHINFO_MAXSIZE` 是 C 宏、Swift 里拿不到（报 `structure not supported`），自己铺 4096 字节缓冲；图标解析要 `NSLock` 缓存（`MonitorAppIcon.shared`，5 分钟过期），并且**只在主线程调用** —— 采样可以在后台，装饰图标不行。

## 发布（GitHub / 插件市场）

- 仓库：<https://github.com/BrightStonebody/dsh-native-tools>（public，topics 含 `dsh-plugin`）
- Release `v2.1.5`（系统监控：面板可关闭 + ✕ 按钮）：`dsh-native-tools.tgz`（稳定名，条目 `tarball:` 指向它）+ `dsh-native-tools-2.1.5.tgz` + `.zip`
- 更早：`v2.1.4`（网速控件预留宽度防抖）、`v2.1.3`（间距对齐系统图标）、`v2.1.2`（图标规则收紧）、`v2.1.1`（两行菜单栏 / App 图标 / 修漂移）、`v2.1.0`（新增系统监控）
- 收录条目：`submission/BrightStonebody__dsh-native-tools.yml`（`category: tools`，`icon` 用 GitHub 托管的 PNG，`tarball` 用 Release 稳定链接）
- 打包/发布脚本（不在仓库里，在工作区根）：`publish-dsh-native-tools.sh`（建仓→推送→topics→Release）、`submit-listing.sh`（fork→放条目→开 PR）
- 市场收录规则里容易踩的：`package.json` 必须声明 `dsh.bundle`（只写 `dsh.client` 会被拒）；仓库要公开且**创建满 1 天**（没有提交数门槛）；条目文件必须是 `data/plugins/<owner>__<repo>.yml`（只深一层）；`icon` 只认 GitHub 托管的位图（SVG 被拒）；`description.en` 必填且单行。`dshmarket` 只是个客户端，不收条目。

23. **`NSPopover` 的 `.transient` 在我们这种组合下关不掉，得自己收**（系统监控，2026-11-16）：app 是 `accessory`、popover 锚在一个自建的 1×1 锚点窗口上，实测「点桌面」不会关闭（用户第一反应就是「怎么关？」）。做法：`MonitorPanelController` 在 `show()` 里装全局鼠标监听（`NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown])`，鼠标全局监听**不需要辅助功能权限**），点到 popover 外就 `hide()`；`hide()` 里记得 `NSEvent.removeMonitor`。收起后紧接着的那次菜单栏按钮点击也会被同一个监听吞掉，所以用 `lastHiddenAt`（0.35 s 窗口）+ `lastHiddenMetric` 区分：点的是刚关掉的图标 → 保持关闭，点的是另一个 → 切换过去。面板右上角还有一个 ✕，但**视图必须 `acceptsFirstMouse` 返回 true**，否则面板不是 key window，第一次点击只激活窗口、事件不投递，✕ 点不动。Esc 不可靠（accessory 进程拿不到本地键盘事件，全局键盘监听要辅助功能权限），页脚文案因此不提 Esc。

## 未完成 / 待办

1. ~~待验证（重启 DSH 后）~~ **已验证（2026-11-15）**：用户重启后看到「插件 › 原生助手」详情页的三张卡与三个开关，并在设置里改过翻译通道。注意这里有两层：`index.js`/`client.js` 改动**必须重启 DSH** 才装载（loader 走 Node 模块缓存），而改设置本身是热更新。
   - 已用隔离环境验过：改 `maxItems` 热生效、改热键热生效（同 pid）、关掉唯一功能 ~150 ms 内退出、全关状态下开功能会自己 spawn、关一个开一个进程不换（翻译通道随之起来）。两个脚本已进仓库：`host-test/live-toggle.mjs`、`host-test/live-switch.mjs`，用法见 `host-test/README.md`。
2. ~~三个旧目录~~ **已删（2026-11-15）**：`dsh-screenshot` / `dsh-clipboard` / `dsh-translate`（含 `helper.retired/`、旧 engine、旧 dist）整体删除；唯二不重复的东西先搬进 `dsh-native-tools/design/`（`icon-1024.png` + `icon.iconset`，图标源文件）。工作区根目录残留的旧独立包 `dsh-clipboard-macos-universal.zip`（`dsh-clipboard/` 112 个文件，含 `__MACOSX/` 垃圾）同日一并删除——它是合并前那个单功能包的构建产物，功能已被 `dsh-native-tools` 覆盖。旧目录里没有 dsh-native-tools 缺的东西：docs 图片更旧、engine 源码与 locale 都是被合并后的副本。
3. **待优化（可选）**：单进程 RSS ≈ 45 MB，合并前三个进程合计 ≈ 26 MB —— 省的是重复代码与进程数，不是内存。若在意，可把 OCR 模型改成按需热身。
4. **收录 PR 已提交（2026-11-16 17:24 +08）**：https://github.com/awesome-dsh-plugin/awesome-dsh-plugin/pull/15869 —— 分支 `BrightStonebody:add-dsh-native-tools`（fork `BrightStonebody/awesome-dsh-plugin`），只改 `data/plugins/BrightStonebody__dsh-native-tools.yml`。CI 两项都过了（`Submission gate` pass；`check` pass，18m52s）。等维护者合并即可，**不要再改这个 PR**（除非 CI 报错）；条目内容要跟版本同步时，下一个 PR 里改。
5. ~~版本号~~ **2.1.5（2026-11-16）**：`dist/dsh-native-tools-2.1.5.zip`，打包入口 `pack.sh`；`dist/` 只留最新那一个包。2.0.2 翻译通道改下拉框（坑 17）→ 2.0.3 截图工具条改成「加红框 / 识别文字 / 保存 / 取消 / 复制」→ 2.0.4 剪贴板底板改回真毛玻璃（坑 18）→ **2.1.0 新增第四个功能「系统监控」**（`Features/Monitor/`：菜单栏三个控件 + 点开看进程排名；坑 19–22）→ **2.1.1 系统监控改版**（2.1.2 又收紧了图标规则：只给真归属 App 的进程画图标）：菜单栏改成「上标签 / 下数字」两行、网络只留 ↑↓ 上下叠加、字号加大；面板每行加进程所属 App 的图标；修掉「面板过一会儿往左下漂」（按钮宽度与面板高度都钉死，见坑 19/20）。**2.1.3 改回 `variableLength` 让间距对齐系统图标**（墨迹间隙 23.0pt vs 19–24.5pt），**2.1.4 再把画布宽度按最坏样本钉住**、**2.1.5 面板可关闭**（全局鼠标监听 + ✕，坑 23）（网速文案在 0B/512B/1024B/999M 之间跳，实测三项宽度恒为 53/53/68pt），防漂移靠面板固定锚点（坑 19/20）。每版都按「解压 → `./install.sh` → 各段 self-test」验过，当前 screenshot 20 / clipboard 55 / translate 11 / monitor 58 全过。

## 验证一次是否还健康

```bash
cd …/default-workspace/dsh-native-tools
pgrep -fl "DSHNative.app/Contents/MacOS/DSHNative"      # 应该只有一个进程
./helper/DSHNative.app/Contents/MacOS/DSHNative --status # 三个 feature 同一 pid、attached=True、热键 ⇧⌘A / ⇧⌘V / ⇧⌘T
```

真机冒烟（同一进程里三件事）：截图 `capture → select [300,360,520,260] → save-to /tmp/a.png`；剪贴板 `snapshot`；翻译 `translate text="The quick brown fox…"` → `hide`。
