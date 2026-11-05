#!/bin/bash
# 打包发布用 DMG：构建 .app → 组装（O.app + Applications 快捷方式 + LICENSE）
# → hdiutil 压缩 → 校验 → 生成 SHA-256 校验文件。
#
# 产物：
#   dist/O-<版本号>.dmg
#   dist/O-<版本号>.dmg.sha256   （`shasum -a 256 -c` 可直接校验）
#
# 版本号唯一来源：仓库根目录 VERSION（与 build_app.sh / Components.swift 强校验一致）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="O"
APP_PATH="$ROOT/.build/app/O.app"
DIST_DIR="$ROOT/dist"

VERSION_FILE="$ROOT/VERSION"
[ -f "$VERSION_FILE" ] || { echo "!! 缺少 VERSION 文件，退出。" >&2; exit 1; }
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[ -n "$VERSION" ] || { echo "!! VERSION 为空，退出。" >&2; exit 1; }

COMPONENTS_VERSION="$(sed -nE 's/.*static let (fallbackVersion|version) = "([^"]+)".*/\2/p' \
    "$ROOT/Sources/MoleLiteApp/Views/Components.swift" | head -1)"
if [ -z "$COMPONENTS_VERSION" ]; then
    echo "!! 无法从 Components.swift 解析版本号，退出。" >&2
    exit 1
fi
if [ "$COMPONENTS_VERSION" != "$VERSION" ]; then
    echo "!! 版本号不一致：VERSION=${VERSION}，Components.swift=$COMPONENTS_VERSION" >&2
    exit 1
fi

DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
SHA_PATH="$DMG_PATH.sha256"

echo "==> 构建 $APP_NAME.app（版本 ${VERSION}）"
bash "$ROOT/build_app.sh"

if [ ! -d "$APP_PATH" ]; then
    echo "!! 未找到 ${APP_PATH}，构建可能失败。" >&2
    exit 1
fi

# 版本二次校验：以 .app 内 Info.plist 为准，防止旧产物被打包
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "!! .app 内版本（${BUILT_VERSION:-未知}）与 VERSION（${VERSION}）不一致，退出。" >&2
    exit 1
fi
if [ ! -f "$APP_PATH/Contents/Resources/LICENSE" ]; then
    echo "!! .app 内缺少 LICENSE，退出（build_app.sh 应已复制）。" >&2
    exit 1
fi

echo "==> 组装 DMG 内容（${APP_NAME} ${VERSION}）"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/o-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/LICENSE" "$STAGING/LICENSE"

echo "==> 生成 $DMG_PATH"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$SHA_PATH"
if ! hdiutil create -volname "$APP_NAME" \
        -srcfolder "$STAGING" \
        -format UDZO \
        -ov \
        "$DMG_PATH" > /dev/null; then
    echo "!! hdiutil 创建 DMG 失败。" >&2
    echo "!! 常见原因：受限沙箱 / 无权限访问 /dev/rdisk*（hdiutil 底层 newfs_apfs 报 Operation not permitted）。" >&2
    echo "!! 请在普通终端或 CI（GitHub Actions macos runner）中运行本脚本。" >&2
    exit 1
fi

echo "==> 校验 DMG"
if ! hdiutil verify "$DMG_PATH" > /dev/null; then
    echo "!! hdiutil verify 校验 DMG 失败。" >&2
    exit 1
fi

echo "==> 写入 SHA-256 校验文件"
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$SHA_PATH")" )
if ! ( cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$SHA_PATH")" > /dev/null ); then
    echo "!! SHA-256 校验失败，退出。" >&2
    exit 1
fi
SHA_VALUE="$(awk '{print $1}' "$SHA_PATH")"

# 签名 / 公证状态：ad-hoc 或未签名时必须明确提示
SIGN_INFO="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 || true)"
SIGNED_STATE="未签名"
if printf '%s' "$SIGN_INFO" | grep -q "Authority=Developer ID Application"; then
    SIGNED_STATE="Developer ID Application 已签名"
elif printf '%s' "$SIGN_INFO" | grep -q "Signature=adhoc"; then
    SIGNED_STATE="ad-hoc 签名"
fi
NOTARIZED_STATE="未公证"
if printf '%s' "$SIGN_INFO" | grep -q "Authority=Developer ID Application"; then
    if spctl -a -t open --context context:primary-signature "$DMG_PATH" > /dev/null 2>&1; then
        NOTARIZED_STATE="已通过 Gatekeeper 校验（Developer ID + 公证）"
    else
        NOTARIZED_STATE="未通过 Gatekeeper 校验（可能未公证）；分发前请执行 notarytool + stapler"
    fi
fi

SIZE="$(du -h "$DMG_PATH" | cut -f1 | xargs)"
echo ""
echo "DMG 打包完成："
echo "  文件    ：${DMG_PATH}"
echo "  版本    ：${VERSION}"
echo "  大小    ：${SIZE}"
echo "  SHA-256 ：${SHA_VALUE}"
echo "  校验文件：${SHA_PATH}"
echo "  签名    ：${SIGNED_STATE}"
echo "  公证    ：${NOTARIZED_STATE}"
echo "  内含    ：O.app、Applications 快捷方式、LICENSE"
echo ""
echo "校验命令："
echo "  shasum -a 256 -c \"${SHA_PATH##*/}\""
echo ""
echo "安装方式：双击 DMG，把 O 拖入 Applications 文件夹。"
echo "Gatekeeper（macOS 13 / 14 / 15）首次打开被拦截时："
echo "  - 系统设置 › 隐私与安全性 › 安全性，点「仍要打开」，再确认「打开」；"
echo "  - 或在「应用程序」中右键 O.app › 打开 › 打开；"
echo "  - 仍不行时：xattr -dr com.apple.quarantine \"/Applications/O.app\" 后再打开。"
if [ "$SIGNED_STATE" != "Developer ID Application 已签名" ]; then
    echo ""
    echo "!! 当前为${SIGNED_STATE}且${NOTARIZED_STATE}：适合本机/小范围使用，"
    echo "!! 面向大众分发需配置 Developer ID 签名并完成公证（xcrun notarytool submit + stapler）。"
fi
