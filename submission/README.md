# 发布到 DSH 插件市场（dsh-market）

先分清三样东西——「发布到 dsh-market」不是往市场应用里上传什么东西：

| 名字 | 是什么 | 要不要投稿 |
| --- | --- | --- |
| `awesome-dsh-plugin/awesome-dsh-plugin` | 精选列表仓库，条目唯一数据源（`data/plugins/*.yml`） | ✅ 提 PR 到这里 |
| `awesome-dsh-plugin.com` | 由上面数据生成的目录站，市场每次打开实时拉取 | 自动收录 |
| `dsh-market`（npm 包名 `dshmarket`） | 市场应用本身 | ❌ 不收条目 |

所以真正的动作只有两步：**把这个包放进一个公开 GitHub 仓库，然后往 `awesome-dsh-plugin` 提一个 YAML 条目的 PR。**

## 当前进度

- [x] 插件改名为 `dsh-native-tools`（包名、patch 行 id、客户端槽位键）
- [x] 本地 git 仓库与首次提交（`main` 分支）
- [ ] 推送到 `https://github.com/BrightStonebody/dsh-native-tools`（公开仓库）
- [ ] 给仓库加 `dsh-plugin` topic
- [ ] 提收录 PR（`data/plugins/BrightStonebody__dsh-native-tools.yml`）

条目内容已写好：[`BrightStonebody__dsh-native-tools.yml`](BrightStonebody__dsh-native-tools.yml)，提 PR 时原样放到列表仓库的 `data/plugins/` 下即可。

## 列表仓库的硬性要求（CI 会逐条卡）

- 仓库**公开**，且创建满 **1 天**（`MIN_AGE_DAYS = 1`，没有提交数门槛）；
- `package.json` 里声明 `dsh.bundle`（本包是 `dsh.bundle.patch: ./cordis.patch.yml` ✅）——只声明 `dsh.client` 是最常见的被拒原因；
- 仓库带 **`dsh-plugin`** topic；
- 一个插件一个 YAML：`data/plugins/<owner>__<repo>.yml`，条目里的 `url` 与仓库地址完全一致；
- `category` 取固定集合之一（本条目用 `tools`）；
- `description.en` **必填**，以句号结尾；`zh` 可选；
- `icon:` 只接受 GitHub 托管的**位图**，SVG 会被拒（本条目指向 `design/icon-1024.png`；仓库里的 `icon.svg` 只给 DSH 插件页用）；
- PR 只改自己的条目，一个 PR 最多 3 条。

## 两条轨道的区别

- **只有 GitHub 仓库**：已经能被市场搜到（`plugins.json` 收 GitHub-only 条目），但这个仓库得先被列表仓收录才有条目。
- **另外发布到 npm**：`index.json` 只收已发 npm 的包，且靠 `probe-npm.mjs` 采集——条件是 registry 里该包的 `repository` 字段指回插件仓库。本包刻意保留 `private: true`（避免误发 npm），需要走这条轨道时再去掉。
