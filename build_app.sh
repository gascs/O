#!/usr/bin/env bash
# 构建 O.app（macOS 13+，SwiftUI）
# 用法：
#   ./build_app.sh          构建 .app
#   ./build_app.sh --open   构建后立即打开
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="O"
BUNDLE_ID="com.o.app"
VERSION="0.4.0"
BUILD_DIR="$ROOT/.build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macos13.0"

mkdir -p "$BUILD_DIR"

fail() {
    echo "" >&2
    echo "构建失败：$1" >&2
    echo "日志：$2" >&2
    echo "建议：运行 bash doctor.sh 查看工具链状态；SwiftPM 为主要路径，失败时会自动回退 swiftc。" >&2
    exit 1
}

# 自动探测 SwiftPM 是否可用。清单不可用时（例如工具链未完整安装），
# swift build 会在编译 manifest 阶段失败，这里提前识别并走 swiftc。
SWIFTPM_OK=0
if swift package --package-path "$ROOT" dump-package > "$BUILD_DIR/swift-package-probe.log" 2>&1; then
    SWIFTPM_OK=1
fi

# ---------------------------------------------------------------------------
# 仅装 Command Line Tools 时，CLT 自带的 module.modulemap 与 bridging.modulemap
# 同时定义了 SwiftBridging，会让所有 swiftc 编译报 "redefinition of module"。
# 这里用一个 VFS overlay 把重复的 modulemap 隐藏掉（仅在该环境下启用）。
# ---------------------------------------------------------------------------
EXTRA_FLAGS=()
CLT_HEADER="/Library/Developer/CommandLineTools/usr/include/swift"
if [ "$(xcode-select -p 2>/dev/null || true)" = "/Library/Developer/CommandLineTools" ] \
   && [ -f "$CLT_HEADER/module.modulemap" ] && [ -f "$CLT_HEADER/bridging.modulemap" ]; then
    : > "$BUILD_DIR/empty.modulemap"
    cat > "$BUILD_DIR/vfs-overlay.yaml" <<YAML
version: 0
case-sensitive: true
roots:
  - type: file
    name: $CLT_HEADER/module.modulemap
    external-contents: $BUILD_DIR/empty.modulemap
YAML
    EXTRA_FLAGS=(-vfsoverlay "$BUILD_DIR/vfs-overlay.yaml")
    echo "==> 检测到 CLT modulemap 冲突，已启用 VFS overlay 兼容处理"
fi

APP_SOURCES=(
    "$ROOT"/Sources/MoleLiteApp/*.swift
    "$ROOT"/Sources/MoleLiteApp/Views/*.swift
    "$ROOT"/Sources/MoleLiteApp/ViewModels/*.swift
)
CORE_SOURCES=("$ROOT"/Sources/MoleLiteCore/Models/*.swift "$ROOT"/Sources/MoleLiteCore/Services/*.swift)

# ---------------------------------------------------------------------------
# 1. 构建可执行文件：优先 swift build，失败时回退到 swiftc 直编
# ---------------------------------------------------------------------------
BINARY=""
if [ "$SWIFTPM_OK" = "1" ] && swift build -c release --package-path "$ROOT" > "$BUILD_DIR/swift-build.log" 2>&1; then
    BINARY="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$APP_NAME"
    BUILD_MODE="SwiftPM (swift build -c release)"
else
    if [ "$SWIFTPM_OK" = "0" ]; then
        echo "==> SwiftPM 清单不可用，回退到 swiftc 直接编译"
    else
        echo "==> swift build 失败（详见 .build/app/swift-build.log），回退到 swiftc 直接编译"
    fi
    BUILD_MODE="swiftc 直接编译（无需 Xcode）"

    NEED_COMPILE=1
    if [ -x "$BUILD_DIR/$APP_NAME" ] \
       && [ -f "$BUILD_DIR/libMoleLiteCore.a" ] \
       && [ -f "$BUILD_DIR/MoleLiteCore.swiftmodule" ]; then
        NEWER="$(find "$ROOT/Sources" "$ROOT/Tools/MakeIcon.swift" -type f \
                 -newer "$BUILD_DIR/$APP_NAME" -print -quit 2>/dev/null)"
        [ -z "$NEWER" ] && NEED_COMPILE=0
    fi

    if [ "$NEED_COMPILE" = "1" ]; then
        swiftc -emit-module -emit-library -static \
            -module-name MoleLiteCore \
            -target "$TARGET" -sdk "$SDK" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -O \
            -o "$BUILD_DIR/libMoleLiteCore.a" \
            -emit-module-path "$BUILD_DIR/MoleLiteCore.swiftmodule" \
            "${CORE_SOURCES[@]}" 2> "$BUILD_DIR/core-build.log" \
            || fail "MoleLiteCore 编译失败（swiftc 返回非零）" "$BUILD_DIR/core-build.log"

        swiftc -parse-as-library -module-name MoleLite \
            -I "$BUILD_DIR" -L "$BUILD_DIR" -lMoleLiteCore \
            -target "$TARGET" -sdk "$SDK" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -O \
            "${APP_SOURCES[@]}" -o "$BUILD_DIR/$APP_NAME" 2> "$BUILD_DIR/app-build.log" \
            || fail "应用目标编译失败（swiftc 返回非零）" "$BUILD_DIR/app-build.log"
    else
        echo "==> 源文件未变化，复用已有二进制（增量构建）"
        BUILD_MODE="$BUILD_MODE · 增量"
    fi

    BINARY="$BUILD_DIR/$APP_NAME"
fi

if [ ! -x "$BINARY" ]; then
    echo "构建失败：找不到可执行文件 $BINARY" >&2
    exit 1
fi
echo "==> 构建方式：$BUILD_MODE"

# ---------------------------------------------------------------------------
# 2. 组装 .app
# ---------------------------------------------------------------------------
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>O</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>O —— 本地磁盘清理工具</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>O 需要读取「下载」文件夹以统计大文件体积，只读取文件大小，不会上传或修改内容。</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>O 需要读取「文档」文件夹以统计大文件体积，只读取文件大小，不会上传或修改内容。</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>O 需要读取「桌面」以统计相关体积，只读取文件大小。</string>
</dict>
</plist>
PLIST

plutil -lint "$APP_BUNDLE/Contents/Info.plist" > /dev/null

# ---------------------------------------------------------------------------
# 3. 图标：应用图标（O 圆环）+ 菜单栏 template 图标
# ---------------------------------------------------------------------------
if swiftc -O "$ROOT/Tools/MakeIcon.swift" -target "$TARGET" -sdk "$SDK" \
      ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -o "$BUILD_DIR/makeicon" > /dev/null 2>&1; then
    "$BUILD_DIR/makeicon" "$BUILD_DIR" > /dev/null
    if iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" > /dev/null 2>&1; then
        echo "==> 图标：AppIcon.icns（1024/512/256/128/32/16 含 @2x）"
    else
        echo "==> 图标：iconutil 失败，跳过（应用仍可运行）"
    fi
    # 菜单栏单色 template 图（18×18 / 36×36），深色浅色自动适配
    cp "$BUILD_DIR/MenuBarIconTemplate.png" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
    cp "$BUILD_DIR/MenuBarIconTemplate@2x.png" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
    echo "==> 菜单栏图标：MenuBarIconTemplate.png / @2x（template）"
else
    echo "==> 图标：生成器编译失败，跳过（应用仍可运行）"
fi

# ---------------------------------------------------------------------------
# 4. Ad-hoc 签名（本机运行足够；分发需自行换 Developer ID）
# ---------------------------------------------------------------------------
codesign --force --sign - "$APP_BUNDLE" > /dev/null 2>&1 || true
codesign --verify --verbose=1 "$APP_BUNDLE" > /dev/null 2>&1 && SIGN_STATE="已做 ad-hoc 签名" || SIGN_STATE="签名校验失败"

echo "==> $SIGN_STATE"
echo ""
echo "构建完成："
echo "  .app      : $APP_BUNDLE"
echo "  可执行文件: $APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo ""
echo "启动方式： open \"$APP_BUNDLE\""

if [ "${1:-}" = "--open" ]; then
    open "$APP_BUNDLE"
fi
