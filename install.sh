#!/bin/bash
# 把原生助手的 helper 准备好：去掉传输带来的 quarantine、重新做本地 ad-hoc 签名。
# 这个 helper（DSHNative.app）是截图 / 剪贴板 / 翻译三个功能共用的同一个进程。
# 只管 helper 这个 .app，不碰 DSH 的 profile（插件本身用 DSH 的「插件 › 添加插件」安装）。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/helper/DSHNative.app"
BIN="$APP/Contents/MacOS/DSHNative"

if [ ! -d "$APP" ]; then
  echo "找不到 helper：$APP" >&2
  exit 1
fi
if ! lipo -archs "$BIN" >/dev/null 2>&1; then
  echo "helper 可执行文件不完整：$BIN" >&2
  exit 1
fi

# AirDrop / 浏览器下载 / 解压 zip 都会给 .app 打上 com.apple.quarantine；
# 没签名的（ad-hoc 签的）app 带着这个属性会被 Gatekeeper 直接拒绝。
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
# 在本机重签一次：ad-hoc 签名跨机器搬动后容易失效，重签最省事。
# 屏幕录制权限记在「负责进程」（DeepSeek Harness）名下，重签 helper 不会弄丢授权。
codesign --force --sign - --identifier ai.deepseek.dsh.native-helper "$APP" >/dev/null 2>&1 || {
  echo "签名失败（缺 Xcode 命令行工具？）。安装 Xcode Command Line Tools 后重试：xcode-select --install" >&2
  exit 1
}

echo "helper 就绪：$APP"
echo "架构：$(lipo -archs "$BIN")"
echo
echo "接下来在同一台机器上："
echo "  1. 打开 DSH › 左侧「插件」› 添加插件 › 安装第三方插件"
echo "  2. 填这个目录：$DIR"
echo "  3. 重启 DSH，刷新页面；然后在「系统设置 › 隐私与安全性 › 屏幕录制」里勾上 DeepSeek Harness"
echo "  4. 三个功能各有开关（插件页 › 原生助手 › 配置），默认快捷键 ⇧⌘A 截图 / ⇧⌘V 剪贴板 / ⇧⌘T 翻译"
