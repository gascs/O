#!/bin/bash
# 打包发布用 DMG：构建 .app → 组装（O.app + Applications 快捷方式）→ hdiutil 压缩 → 校验。
# 产物：dist/O-<版本号>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="O"
APP_PATH="$ROOT/.build/app/O.app"
VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/Sources/MoleLiteApp/Views/Components.swift" | head -1)"
if [ -z "$VERSION" ]; then
    echo "!! 无法从 Components.swift 解析版本号，退出。" >&2
    exit 1
fi

DIST_DIR="$ROOT/dist"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> 构建 $APP_NAME.app"
bash "$ROOT/build_app.sh"

if [ ! -d "$APP_PATH" ]; then
    echo "!! 未找到 $APP_PATH，构建可能失败。" >&2
    exit 1
fi

echo "==> 组装 DMG 内容（${APP_NAME} ${VERSION}）"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> 生成 $DMG_PATH"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -ov \
    "$DMG_PATH" > /dev/null

echo "==> 校验 DMG"
hdiutil verify "$DMG_PATH" > /dev/null

SIZE="$(du -h "$DMG_PATH" | cut -f1 | xargs)"
echo ""
echo "DMG 打包完成："
echo "  文件：${DMG_PATH}"
echo "  版本：${VERSION}"
echo "  大小：${SIZE}"
echo ""
echo "安装方式：双击 DMG，把 O 拖入 Applications 文件夹。"
echo "提示：当前为 ad-hoc 签名，首次打开需在「系统设置 › 隐私与安全性」允许运行；"
echo "      分发给他人建议配置 Developer ID 签名并公证（notarytool）。"
