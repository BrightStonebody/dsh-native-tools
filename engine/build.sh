#!/bin/bash
# 就地构建原生助手并装进本包的 helper/DSHNative.app。
#
# 源码就在本包内（engine/Sources/NativeKit），所以这个脚本是「唯一的」构建入口：
# 三个功能编进同一个二进制，改完 Swift 跑一次即可，装完不必重装插件。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
APP="$PLUGIN_DIR/helper/DSHNative.app"

[ -d "$APP" ] || { echo "缺少 helper 目录：$APP" >&2; exit 1; }
[ -d "$HERE/Sources/NativeKit" ] || { echo "缺少源码：$HERE/Sources/NativeKit" >&2; exit 1; }

cd "$HERE"
SOURCES=(Sources/NativeKit/Core/*.swift Sources/NativeKit/Features/Screenshot/*.swift \
         Sources/NativeKit/Features/Clipboard/*.swift Sources/NativeKit/Features/Translate/*.swift \
         Sources/NativeKit/main.swift)

mkdir -p build
swiftc -O -target arm64-apple-macos13.0 -o build/DSHNative-arm64 "${SOURCES[@]}"
swiftc -O -target x86_64-apple-macos13.0 -o build/DSHNative-x86_64 "${SOURCES[@]}"
lipo -create -output build/DSHNative build/DSHNative-arm64 build/DSHNative-x86_64

cp build/DSHNative "$APP/Contents/MacOS/DSHNative"
codesign --force --sign - --identifier ai.deepseek.dsh.native-helper "$APP" >/dev/null 2>&1 || true

echo "已安装：${APP}（架构 $(lipo -archs "${APP}/Contents/MacOS/DSHNative")）"
echo "自测：$HERE/build/DSHNative --self-test --feature screenshot|clipboard|translate"
