#!/bin/bash
# 打一个可以拷到别的机器上解压使用的 zip：dist/dsh-native-tools-<版本>.zip
#
# 只装运行需要的东西（Host 半边、客户端脚本、helper、安装脚本、文档），
# 带上 engine/ 源码是为了对方能自己重编；不带的东西：
#   engine/build/    编译中间产物，几 MB 的死重量
#   host-test/       开发期的自测，依赖本机 DSH 的 node 与路径
#   HANDOFF.md       内部交接笔记
#   dist/            zip 不能装自己
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

VERSION="$(python3 -c 'import json,sys; print(json.load(open("package.json"))["version"])')"
OUT="$DIR/dist/dsh-native-tools-$VERSION.zip"

# 打包前先确认 helper 是通用二进制、且和源码目录对得上，别把半成品发出去。
BIN="$DIR/helper/DSHNative.app/Contents/MacOS/DSHNative"
[ -x "$BIN" ] || { echo "缺少 helper 可执行文件：$BIN" >&2; exit 1; }
ARCHS="$(lipo -archs "$BIN")"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) echo "helper 不是通用二进制（lipo -archs = $ARCHS）" >&2; exit 1 ;;
esac

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/dsh-native-tools"
mkdir -p "$ROOT"

for item in \
  package.json index.js client.js translate-host.js cordis.patch.yml \
  locale icon.svg design helper install.sh README.md docs engine
do
  [ -e "$item" ] || { echo "缺少 $item" >&2; exit 1; }
  cp -R "$item" "$ROOT/"
done
# engine/build 是编译中间产物，几 MB 的死重量。
rm -rf "$ROOT/engine/build"
# 拷贝会带上扩展属性；这里统一清掉，免得 zip 里带一堆 xattr。
find "$ROOT" -name '.DS_Store' -delete

mkdir -p "$DIR/dist"
rm -f "$OUT"
( cd "$STAGE" && zip -r -X -q "$OUT" dsh-native-tools )

# 同一份内容再打一个 .tgz：GitHub Release 上挂这个，DSH 插件市场的条目用
# tarball: 指向它（市场只接受 GitHub Release 上的 https .tgz）。
# 另存一份不带版本号的副本，方便 releases/latest/download/dsh-native-tools.tgz
# 这种稳定链接。
TGZ="$DIR/dist/dsh-native-tools-$VERSION.tgz"
TGZ_STABLE="$DIR/dist/dsh-native-tools.tgz"
rm -f "$TGZ" "$TGZ_STABLE"
( cd "$STAGE" && tar -czf "$TGZ" dsh-native-tools )
cp "$TGZ" "$TGZ_STABLE"

echo "已生成：$OUT"
echo "        ${TGZ}（Release 用）"
echo "大小：$(du -h "$OUT" | cut -f1) / $(du -h "$TGZ" | cut -f1)"
echo "helper：$ARCHS"
echo "文件数：$(unzip -l "$OUT" | tail -1 | awk '{print $2}')"
echo
echo "装到别的机器上："
echo "  1. 解压到固定目录（别放「下载」里，插件配置记的是这个路径）"
echo "  2. 跑 ./install.sh 去掉 quarantine 并重新签名"
echo "  3. DSH › 插件 › 添加插件 › 安装第三方插件，填解压后的 dsh-native-tools 目录"
