#!/usr/bin/env bash
# 构建 O.app（macOS 13+，SwiftUI）
#
# 用法：
#   ./build_app.sh          构建 .app
#   ./build_app.sh --open   构建后立即打开
#
# 版本号唯一来源：仓库根目录 VERSION 文件。
#   - Info.plist 的 CFBundleShortVersionString 直接来自 VERSION
#   - CFBundleVersion 由 VERSION 换算（0.5.0 → 500）
#   - Sources/MoleLiteApp/Views/Components.swift 的 fallbackVersion 必须与 VERSION 相同，
#     否则本脚本直接报错退出（避免 App 内版本与安装包版本漂移）
#
# 产物：.build/app/O.app（默认 universal：arm64 + x86_64）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="O"
BUNDLE_ID="com.o.app"
BUILD_DIR="$ROOT/.build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macos13.0"
# 受限环境（沙箱 / CI）下 SwiftPM 自己的构建沙箱可能无法写临时目录，默认关闭；
# 需要保留 SwiftPM 沙箱时设 O_SWIFT_SANDBOX=1。
SWIFT_FLAGS=(--disable-sandbox)
if [ "${O_SWIFT_SANDBOX:-0}" = "1" ]; then
    SWIFT_FLAGS=()
fi

mkdir -p "$BUILD_DIR"

fail() {
    echo "" >&2
    echo "构建失败：$1" >&2
    if [ -n "${2:-}" ]; then echo "日志：$2" >&2; fi
    echo "建议：运行 bash doctor.sh 查看工具链状态。" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 0. 版本号：VERSION 是唯一来源；Components.swift 只允许跟随，不允许分歧
# ---------------------------------------------------------------------------
VERSION_FILE="$ROOT/VERSION"
[ -f "$VERSION_FILE" ] || fail "缺少 VERSION 文件（仓库根目录），无法确定版本号"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "VERSION 内容不是合法的 x.y.z 版本号：'$VERSION'" ;;
esac

COMPONENTS_FILE="$ROOT/Sources/MoleLiteApp/Views/Components.swift"
[ -f "$COMPONENTS_FILE" ] || fail "缺少 $COMPONENTS_FILE"
COMPONENTS_VERSION="$(sed -nE 's/.*static let (fallbackVersion|version) = "([^"]+)".*/\2/p' "$COMPONENTS_FILE" | head -1)"
if [ -z "$COMPONENTS_VERSION" ]; then
    fail "无法从 Components.swift 解析版本号常量（fallbackVersion），请确认 AppInfo 未被改动"
fi
if [ "$COMPONENTS_VERSION" != "$VERSION" ]; then
    fail "版本号不一致：VERSION=$VERSION，Components.swift=$COMPONENTS_VERSION（请同步修改后重试）"
fi

# CFBundleVersion：把 x.y.z 换算成单调递增的整数（0.5.0 → 500）
IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<< "$VERSION"
BUILD_NUMBER=$(( 10#${V_MAJOR:-0} * 10000 + 10#${V_MINOR:-0} * 100 + 10#${V_PATCH:-0} ))

echo "==> 版本：$VERSION（CFBundleVersion $BUILD_NUMBER，来源 VERSION）"

# ---------------------------------------------------------------------------
# 1. 构建可执行文件：优先 SwiftPM universal，其次 SwiftPM 本机架构，
#    最后回退 swiftc 直编。任何回退都会显式报错，不再静默降级。
# ---------------------------------------------------------------------------
SWIFTPM_OK=0
# 注意：必须带 --disable-sandbox，否则受限环境（沙箱 / CI 容器）里
# 清单编译会被 sandbox-exec 拒绝（sandbox_apply: Operation not permitted）。
if swift package --disable-sandbox --package-path "$ROOT" dump-package \
        > "$BUILD_DIR/swift-package-probe.log" 2>&1; then
    SWIFTPM_OK=1
fi

# 仅装 Command Line Tools 时，CLT 自带的 module.modulemap 与 bridging.modulemap
# 同时定义了 SwiftBridging，会让所有 swiftc 编译报 "redefinition of module"。
# 这里用一个 VFS overlay 把重复的 modulemap 隐藏掉（仅在该环境下启用）。
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

BINARY=""
BUILD_MODE=""
UNIVERSAL=0

if [ "$SWIFTPM_OK" = "1" ]; then
    # SwiftPM 6.0.3 没有 `--arch` 选项（`swift build --help` 只有 --triple），
    # 因此 universal 用两次 --triple 交叉构建 + lipo 合并；任何一步失败都显式报错再回退。
    echo "==> 编译 release：arm64 + x86_64（分别 --triple，再用 lipo 合并为 universal）"
    ARM_SCRATCH="$BUILD_DIR/universal-arm64"
    X86_SCRATCH="$BUILD_DIR/universal-x86_64"
    ARM_LOG="$BUILD_DIR/swift-build-arm64.log"
    X86_LOG="$BUILD_DIR/swift-build-x86_64.log"
    ARM_BIN=""
    X86_BIN=""
    if swift build -c release --package-path "$ROOT" \
            --triple arm64-apple-macosx13.0 --scratch-path "$ARM_SCRATCH" \
            "${SWIFT_FLAGS[@]}" > "$ARM_LOG" 2>&1; then
        ARM_BIN="$(swift build -c release --package-path "$ROOT" \
            --triple arm64-apple-macosx13.0 --scratch-path "$ARM_SCRATCH" \
            --show-bin-path 2>/dev/null)/$APP_NAME"
    else
        echo "!! arm64 构建失败，详见 $ARM_LOG" >&2
    fi
    if [ -x "$ARM_BIN" ]; then
        if swift build -c release --package-path "$ROOT" \
                --triple x86_64-apple-macosx13.0 --scratch-path "$X86_SCRATCH" \
                "${SWIFT_FLAGS[@]}" > "$X86_LOG" 2>&1; then
            X86_BIN="$(swift build -c release --package-path "$ROOT" \
                --triple x86_64-apple-macosx13.0 --scratch-path "$X86_SCRATCH" \
                --show-bin-path 2>/dev/null)/$APP_NAME"
        else
            echo "!! x86_64 构建失败，详见 $X86_LOG" >&2
        fi
    fi
    if [ -x "$ARM_BIN" ] && [ -x "$X86_BIN" ]; then
        if lipo -create -output "$BUILD_DIR/$APP_NAME-universal" "$ARM_BIN" "$X86_BIN" \
                > "$BUILD_DIR/lipo.log" 2>&1; then
            BINARY="$BUILD_DIR/$APP_NAME-universal"
            BUILD_MODE="SwiftPM (universal: arm64 + x86_64)"
            UNIVERSAL=1
        else
            echo "!! lipo 合并 universal 失败，详见 $BUILD_DIR/lipo.log" >&2
        fi
    fi
    if [ "$UNIVERSAL" != "1" ]; then
        echo "!! universal 构建不可用：回退为本机架构（$(uname -m)），产物不是 universal，请勿直接用于发布。" >&2
        echo "==> 编译 release（本机架构 $(uname -m)）"
        if swift build -c release --package-path "$ROOT" \
                "${SWIFT_FLAGS[@]}" > "$BUILD_DIR/swift-build.log" 2>&1; then
            BINARY="$(swift build -c release --package-path "$ROOT" --show-bin-path 2>/dev/null)/$APP_NAME"
            BUILD_MODE="SwiftPM（回退：本机 $(uname -m)）"
        else
            echo "!! 本机架构 swift build 也失败，回退到 swiftc 直接编译" >&2
            SWIFTPM_OK=0
        fi
    fi
else
    echo "==> SwiftPM 清单不可用，回退到 swiftc 直接编译"
fi

if [ "$SWIFTPM_OK" = "0" ]; then
    BUILD_MODE="swiftc 直接编译（回退：本机 $(uname -m)）"
    UNIVERSAL=0

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
    fail "找不到可执行文件 $BINARY"
fi
echo "==> 构建方式：$BUILD_MODE"

# universal 声明校验：构建方式说 universal，就真的必须是 fat binary
if [ "$UNIVERSAL" = "1" ]; then
    LIPO_INFO="$(lipo -info "$BINARY" 2>/dev/null || true)"
    if printf '%s' "$LIPO_INFO" | grep -q "arm64" && printf '%s' "$LIPO_INFO" | grep -q "x86_64"; then
        echo "==> 架构校验：$(printf '%s' "$LIPO_INFO" | sed 's/^Architectures in the fat file: //')"
    else
        echo "!! 架构校验失败：预期 universal（arm64 + x86_64），实际：${LIPO_INFO:-未知}" >&2
        echo "!! 产物将按单架构继续打包；发布前请修复通用构建。" >&2
        UNIVERSAL=0
    fi
fi

# ---------------------------------------------------------------------------
# 2. 组装 .app（清理旧 bundle 前先做路径校验）
# ---------------------------------------------------------------------------
case "$APP_BUNDLE" in
    "$ROOT"/.build/app/*.app) ;;
    *)
        echo "!! 路径校验失败，拒绝删除：$APP_BUNDLE" >&2
        exit 1
        ;;
esac
if [ -z "$APP_BUNDLE" ] || [ "$APP_BUNDLE" = "/" ] || [ "$APP_BUNDLE" = "$HOME" ]; then
    echo "!! 路径校验失败，拒绝删除：$APP_BUNDLE" >&2
    exit 1
fi
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# LICENSE 进 App bundle：分发单个 .app 时也能看到许可证（DMG 里同样放一份）
if [ -f "$ROOT/LICENSE" ]; then
    cp "$ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
else
    echo "!! 未找到 LICENSE，App bundle 内将不含许可证" >&2
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
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
    <string>$BUILD_NUMBER</string>
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
# 4. 签名：有 Developer ID 就用（含 hardened runtime）；没有就 ad-hoc，
#    失败绝不静默——打印原因并继续产出可用但未公证的 .app。
# ---------------------------------------------------------------------------
SIGN_IDENTITY="${O_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && command -v security > /dev/null 2>&1; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/.*"(Developer ID Application[^"]*)".*/\1/p' | head -1)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    SIGN_HINT="ad-hoc（未找到 Developer ID Application 证书；首次打开需在系统设置中允许）"
else
    SIGN_HINT="Developer ID Application：$SIGN_IDENTITY"
fi

if codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE" > "$BUILD_DIR/codesign.log" 2>&1; then
    echo "==> 签名：$SIGN_HINT"
else
    echo "!! 使用 '$SIGN_IDENTITY' 签名失败（详见 $BUILD_DIR/codesign.log）" >&2
    echo "!! 尝试 ad-hoc 签名作为兜底……" >&2
    if codesign --force --sign - "$APP_BUNDLE" >> "$BUILD_DIR/codesign.log" 2>&1; then
        SIGN_HINT="ad-hoc（签名兜底成功；未使用 Developer ID，未公证）"
        echo "==> 签名：$SIGN_HINT"
    else
        SIGN_HINT="未签名（codesign 失败，产物仍可本机运行）"
        echo "!! codesign 失败：$SIGN_HINT；详见 $BUILD_DIR/codesign.log" >&2
    fi
fi

if codesign --verify --verbose=2 "$APP_BUNDLE" > "$BUILD_DIR/codesign-verify.log" 2>&1; then
    echo "==> 签名校验：通过"
else
    echo "!! 签名校验未通过（详见 $BUILD_DIR/codesign-verify.log）：产物可本机运行，但 Gatekeeper 会拦截分发。" >&2
fi
if printf '%s' "$SIGN_HINT" | grep -q "ad-hoc\|未签名"; then
    echo "==> 公证：未公证（ad-hoc 签名无法公证）。公开发布需 Developer ID + notarytool。"
fi

echo ""
echo "构建完成："
echo "  .app      : $APP_BUNDLE"
echo "  版本      : $VERSION（CFBundleVersion $BUILD_NUMBER）"
echo "  架构      : $([ "$UNIVERSAL" = "1" ] && echo "universal（arm64 + x86_64）" || echo "单架构（$(uname -m)）")"
echo "  可执行文件: $APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo "  许可证    : $APP_BUNDLE/Contents/Resources/LICENSE"
echo ""
echo "启动方式： open \"$APP_BUNDLE\""

if [ "${1:-}" = "--open" ]; then
    open "$APP_BUNDLE"
fi
