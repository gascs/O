#!/usr/bin/env bash
# O 环境自检（只读）。不 sudo、不改系统设置、不删用户文件。
# 用法：bash doctor.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="$(xcode-select -p 2>/dev/null || true)"
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/o-doctor.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
OK_COUNT=0
BAD_COUNT=0

ok() {
    OK_COUNT=$((OK_COUNT + 1))
    printf '  [正常] %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '         建议：%s\n' "$2"; fi
}

bad() {
    BAD_COUNT=$((BAD_COUNT + 1))
    printf '  [异常] %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '         建议：%s\n' "$2"; fi
}

info() { printf '  %s\n' "$1"; }

echo "O 环境自检（只读）"
echo "============================================================"

# 1. 系统
echo ""
echo "1) 系统"
info "macOS：$(sw_vers -productVersion 2>/dev/null || echo unknown)（Build $(sw_vers -buildVersion 2>/dev/null || echo unknown)）"
info "架构：${ARCH}"
if [ "${ARCH}" = "arm64" ] || [ "${ARCH}" = "x86_64" ]; then
    ok "架构受支持（${ARCH}）"
else
    bad "未知架构：${ARCH}" "本项目按 arm64 / x86_64 构建，请确认 uname -m 输出"
fi

# 2. 工具链选择
echo ""
echo "2) 工具链选择"
if [ -n "$DEV" ]; then
    info "xcode-select -p：$DEV"
    if [ "$DEV" = "/Library/Developer/CommandLineTools" ]; then
        ok "当前使用 Command Line Tools（无需完整 Xcode）"
    elif [ -d "$DEV" ]; then
        ok "当前使用完整 Xcode 或自定义工具链：$DEV"
    else
        bad "xcode-select 指向不存在的路径：$DEV" "运行 xcode-select --install 安装 CLT；需要管理员权限，doctor.sh 不会自动执行"
    fi
else
    bad "xcode-select 未配置" "运行 xcode-select --install 安装 Command Line Tools"
fi

# 3. CLT 版本
echo ""
echo "3) Command Line Tools"
CLT_INFO="$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null || true)"
if [ -n "$CLT_INFO" ]; then
    CLT_VERSION="$(printf '%s\n' "$CLT_INFO" | awk '/version:/{print $2}')"
    info "CLT 包版本：${CLT_VERSION:-unknown}"
    ok "已安装 Command Line Tools" "若工具链异常，优先用 Apple 官方 CLT 安装包重装同版本，不要手工替换 dylib"
else
    bad "未检测到 CLT 安装记录" "运行 xcode-select --install；或从 Apple Developer 下载对应系统版本的 CLT"
fi

# 4. 编译器
echo ""
echo "4) Swift 编译器"
SWIFTC_VERSION="$(swiftc --version 2>&1 | head -1)"
SWIFT_VERSION="$(swift --version 2>&1 | head -1)"
info "swiftc：$SWIFTC_VERSION"
info "swift ：$SWIFT_VERSION"
if swiftc --version >/dev/null 2>&1; then
    ok "swiftc 可执行"
else
    bad "swiftc 不可执行" "重装 CLT 或运行 xcode-select --install"
fi

# 5. PackageDescription 与 SwiftPM
echo ""
echo "5) PackageDescription / SwiftPM"
MODULE_DIR=""
for candidate in \
    "$DEV/usr/lib/swift/pm/ManifestAPI" \
    "$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI"; do
    if [ -d "$candidate" ]; then MODULE_DIR="$candidate"; break; fi
done

SWIFTPM_OK=0
if [ -n "$MODULE_DIR" ] && [ -d "$MODULE_DIR/PackageDescription.swiftmodule" ]; then
    INTERFACE="$MODULE_DIR/PackageDescription.swiftmodule/${ARCH}-apple-macos.swiftinterface"
    if [ ! -f "$INTERFACE" ]; then
        INTERFACE="$MODULE_DIR/PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface"
    fi
    info "模块：$MODULE_DIR/PackageDescription.swiftmodule"
    info "接口版本：$(grep -m1 'swift-compiler-version' "$INTERFACE" 2>/dev/null | sed 's/^.*: //')"
    if [ -f "$MODULE_DIR/libPackageDescription.dylib" ]; then
        info "dylib：$MODULE_DIR/libPackageDescription.dylib"
        info "dylib 架构：$(lipo -info "$MODULE_DIR/libPackageDescription.dylib" 2>/dev/null | sed 's/^.*: / /')"
        info "dylib 修改时间：$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$MODULE_DIR/libPackageDescription.dylib" 2>/dev/null)"
        if strings "$MODULE_DIR/libPackageDescription.dylib" 2>/dev/null | grep -q 'swiftLanguageModes' \
           && ! strings "$MODULE_DIR/libPackageDescription.dylib" 2>/dev/null | grep -q 'swiftLanguageVersions'; then
            info "符号倾向：dylib 内含 Swift 6 接口，但旧版 manifest 初始化符号缺失（版本不一致的典型表现）"
        fi
    else
        bad "缺少 libPackageDescription.dylib" "重装 CLT 或改用完整 Xcode"
    fi

    mkdir -p "$TMP/pkg/Sources/T"
    cat > "$TMP/pkg/Package.swift" <<'PKG'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Probe",
    targets: [.executableTarget(name: "T", path: "Sources/T")]
)
PKG
    printf 'print("ok")\n' > "$TMP/pkg/Sources/T/main.swift"
    if swift package --disable-sandbox --package-path "$TMP/pkg" dump-package > "$TMP/dump.json" 2> "$TMP/dump.err"; then
        SWIFTPM_OK=1
        ok "SwiftPM 可用（swift build / swift test 可尝试）"
    else
        bad "SwiftPM 清单无法编译或链接" "这是 CLT 的 PackageDescription 模块/库版本不一致；建议重装同版本 CLT 或安装完整 Xcode。当前可继续用 build_app.sh / run_tests.sh"
        if [ -s "$TMP/dump.err" ]; then
            printf '         系统返回：%s\n' "$(grep -m1 -E 'Undefined symbols|error:' "$TMP/dump.err" | cut -c1-160)"
        fi
    fi
else
    bad "找不到 PackageDescription 模块" "重装 CLT 或安装完整 Xcode"
fi

# 6. 可用构建方式
echo ""
echo "6) 构建方式"
DIRECT_OK=0
if [ -n "$SDK" ] && [ -d "$SDK" ]; then
    info "SDK：$SDK"
    if [ "$DEV" = "/Library/Developer/CommandLineTools" ] \
       && [ -f "$DEV/usr/include/swift/module.modulemap" ] \
       && [ -f "$DEV/usr/include/swift/bridging.modulemap" ]; then
        : > "$TMP/empty.modulemap"
        printf 'version: 0\ncase-sensitive: true\nroots:\n  - type: file\n    name: %s\n    external-contents: %s\n' \
            "$DEV/usr/include/swift/module.modulemap" "$TMP/empty.modulemap" > "$TMP/vfs.yaml"
        OVERLAY_FLAGS=(-vfsoverlay "$TMP/vfs.yaml")
        info "检测到 CLT modulemap 冲突，swiftc 直编需要 VFS overlay（build_app.sh 已自动启用）"
    else
        OVERLAY_FLAGS=()
    fi
    printf 'print("ok")\n' > "$TMP/probe.swift"
    if swiftc -target "$TARGET" -sdk "$SDK" "${OVERLAY_FLAGS[@]+"${OVERLAY_FLAGS[@]}"}" \
        "$TMP/probe.swift" -o "$TMP/probe" > "$TMP/probe.log" 2>&1; then
        DIRECT_OK=1
        ok "swiftc 直接编译可用" "无需 Xcode，build_app.sh 可完整构建"
    else
        bad "swiftc 直接编译失败" "查看系统返回；先重装 CLT"
        [ -s "$TMP/probe.log" ] && printf '         系统返回：%s\n' "$(head -2 "$TMP/probe.log" | cut -c1-160)"
    fi
else
    bad "找不到 macOS SDK" "重装 CLT 或安装完整 Xcode"
fi
if [ "$SWIFTPM_OK" = "1" ]; then
    info "推荐：SwiftPM 与 swiftc 均可；build_app.sh 会优先 SwiftPM"
elif [ "$DIRECT_OK" = "1" ]; then
    info "推荐：使用 ./build_app.sh（自动回退 swiftc 直编），无需 Xcode"
else
    bad "没有可用构建路径" "先修复 CLT：xcode-select --install 或安装完整 Xcode"
fi

# 7. 登录项
echo ""
echo "7) 登录启动"
APP_PATH="$ROOT/.build/app/O.app"
INSTALLED_APP="/Applications/O.app"
if [ -d "$APP_PATH" ]; then
    info "源码目录内已构建：$APP_PATH"
else
    bad "尚未构建 O.app" "运行 ./build_app.sh"
fi
if [ -d "$INSTALLED_APP" ]; then
    ok "O.app 位于「应用程序」文件夹" "登录项只在 App 位于 /Applications 时可靠工作"
    INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [ -d "$APP_PATH" ]; then
        BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
        if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" != "$BUILT_VERSION" ]; then
            bad "已安装版本（${INSTALLED_VERSION:-未知}）与刚构建版本（${BUILT_VERSION:-未知}）不一致" \
                "重新运行 ./build_dmg.sh 并用新 DMG 覆盖安装，避免旧版残留"
        else
            ok "已安装版本与构建产物一致（${INSTALLED_VERSION:-未知}）"
        fi
    fi
else
    info "未在 /Applications 找到 O.app" "需要开机自启时，把 O.app 拖入「应用程序」后再在 O 设置里开启「登录时自动打开」"
fi
BTM_DUMP="$(sfltool dumpbtm 2>&1 || true)"
if printf '%s' "$BTM_DUMP" | grep -q "com.o.app"; then
    ok "系统登录项数据库中存在 com.o.app" "在系统设置 › 通用 › 登录项 中确认状态"
elif printf '%s' "$BTM_DUMP" | grep -q -E "Error|error|denied|4097"; then
    bad "无法读取系统登录项数据库" "本会话没有 backgroundtaskmanagement 权限；请在「系统设置 › 通用 › 登录项」手动查看 O 的状态"
else
    info "系统登录项数据库中未发现 com.o.app（未注册或未安装到 Applications）"
fi

# 8. 完全磁盘访问（与 App 设置页使用完全相同的判定规则：
#    只读 Mail / Safari / TCC 三个受保护位置；任一可读=已授权，全都读不到=未授权，
#    路径都不存在=无法判定，绝不把终止判为已授权。废纸篓单列，不计入 FDA。）
echo ""
echo "8) 完全磁盘访问（FDA）"
FDA_READABLE=0
FDA_EXISTING=0
FDA_MISSING_ALL=1
for rel in "Library/Mail" "Library/Safari" "Library/Application Support/com.apple.TCC"; do
    p="$HOME/$rel"
    if [ ! -e "$p" ]; then
        printf '         %s：路径不存在\n' "$rel"
        continue
    fi
    FDA_MISSING_ALL=0
    FDA_EXISTING=$((FDA_EXISTING + 1))
    if [ -r "$p" ] && ls "$p" >/dev/null 2>&1; then
        FDA_READABLE=1
        printf '         %s：可读取\n' "$rel"
    else
        printf '         %s：读取被拒绝\n' "$rel"
    fi
done
if [ "$FDA_READABLE" = "1" ]; then
    ok "完全磁盘访问：已授权（与设置页结论一致）" "无需再授权；O 可读取受保护位置"
elif [ "$FDA_MISSING_ALL" = "1" ]; then
    info "完全磁盘访问：无法判定（三个受保护路径都不存在）" "这不会被当成已授权；安装并打开 O 后按界面引导检测"
elif [ "$FDA_EXISTING" -gt 0 ]; then
    bad "完全磁盘访问：未授权（受保护路径存在但都读不到）" "在 系统设置 › 隐私与安全性 › 完全磁盘访问 中打开 O；doctor.sh 不会改动隐私设置"
fi
if [ -d "$HOME/.Trash" ]; then
    if [ -r "$HOME/.Trash" ] && ls "$HOME/.Trash" >/dev/null 2>&1; then
        info "废纸篓：可读取" "清理项可正常移入废纸篓"
    else
        bad "废纸篓：读取被拒绝" "O 会把相关功能标注「受限」，不影响其他清理项"
    fi
else
    info "废纸篓：目录不存在，无法判定" "不会被当成已授权"
fi

# 9. 版本号与发布产物
echo ""
echo "9) 版本号与发布产物"
VERSION_FILE="$ROOT/VERSION"
if [ -f "$VERSION_FILE" ]; then
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
    if [ -n "$VERSION" ]; then
        ok "VERSION 存在且非空：$VERSION"
    else
        bad "VERSION 为空" "写入形如 0.5.0 的版本号（唯一版本来源）"
    fi
else
    VERSION=""
    bad "缺少 VERSION 文件" "在仓库根目录创建 VERSION，内容为当前版本号（如 0.5.0）"
fi
COMPONENTS_VERSION=""
COMPONENTS_FILE="$ROOT/Sources/MoleLiteApp/Views/Components.swift"
if [ -f "$COMPONENTS_FILE" ]; then
    COMPONENTS_VERSION="$(sed -nE 's/.*static let (fallbackVersion|version) = "([^"]+)".*/\2/p' \
        "$COMPONENTS_FILE" | head -1)"
fi
if [ -z "$COMPONENTS_VERSION" ]; then
    bad "无法从 Components.swift 解析版本号" "检查 AppInfo.fallbackVersion 是否为字符串字面量"
elif [ -n "$VERSION" ] && [ "$COMPONENTS_VERSION" != "$VERSION" ]; then
    bad "Components.swift 版本（$COMPONENTS_VERSION）与 VERSION（$VERSION）不一致" \
        "build_app.sh 会因此直接失败；把两者改成同一版本号"
else
    ok "Components.swift 版本与 VERSION 一致（${COMPONENTS_VERSION}）"
fi
if [ -d "$APP_PATH" ] && [ -n "$VERSION" ]; then
    PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$PLIST_VERSION" = "$VERSION" ]; then
        ok "构建产物 Info.plist 版本一致（${PLIST_VERSION}）"
    else
        bad "构建产物 Info.plist 版本（${PLIST_VERSION:-未知}）与 VERSION（$VERSION）不一致" \
            "重新运行 ./build_app.sh"
    fi
fi
if [ -n "$VERSION" ]; then
    DMG_PATH="$ROOT/dist/O-$VERSION.dmg"
    SHA_PATH="$DMG_PATH.sha256"
    if [ -f "$DMG_PATH" ]; then
        ok "已生成 $DMG_PATH" "大小：$(du -h "$DMG_PATH" | cut -f1 | xargs)"
        if [ -f "$SHA_PATH" ]; then
            if ( cd "$ROOT/dist" && shasum -a 256 -c "$(basename "$SHA_PATH")" > /dev/null 2>&1 ); then
                ok "DMG 的 SHA-256 校验通过（$(basename "$SHA_PATH")）"
            else
                bad "DMG 的 SHA-256 校验失败" "DMG 可能被改动或未完整生成；重新运行 ./build_dmg.sh"
            fi
        else
            bad "缺少 $(basename "$SHA_PATH")" "重新运行 ./build_dmg.sh 生成校验文件"
        fi
    else
        info "尚未生成 O-$VERSION.dmg（发布前运行 ./build_dmg.sh）"
    fi
fi

echo ""
echo "============================================================"
printf '摘要：%d 项正常，%d 项异常\n' "$OK_COUNT" "$BAD_COUNT"
echo "说明：本脚本只做读取与临时目录内的编译探针，不 sudo、不修改系统设置、不删除用户文件。"
if [ "$BAD_COUNT" -gt 0 ]; then
    echo "结论：存在 ${BAD_COUNT} 项异常，请按「建议」处理；本脚本以非零退出码结束。"
    exit 1
fi
echo "结论：全部检查通过。"

