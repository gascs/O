#!/usr/bin/env bash
# 运行全部测试并如实报告数量：
#   1) swift build        —— 确认可执行 target（App）能编译，避免「测试过但 App 编不过」
#   2) XCTest（swift test）—— 按「测试用例」计数，失败也保留真实数字
#   3) Tools/SelfTest      —— 按「断言项」计数，不依赖 XCTest
#
# 任一套失败 → 非零退出；失败时不清零计数，只把失败数如实挂出来。
#
# --disable-sandbox 是受限环境（沙箱 / CI 容器）必需：SwiftPM 默认构建沙箱
# 会因无法写临时目录而失败。
#
# 可选环境变量：
#   O_SCRATCH_PATH  指定 SwiftPM scratch 目录（与并行构建隔离时用，CI 不需要）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/.build/app"
SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macos13.0"
mkdir -p "$BUILD_DIR"

SCRATCH_ARGS=()
if [ -n "${O_SCRATCH_PATH:-}" ]; then
    SCRATCH_ARGS=(--scratch-path "$O_SCRATCH_PATH")
fi

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
fi

XCTEST_LOG="$BUILD_DIR/swift-test.log"
BUILD_LOG="$BUILD_DIR/swift-build-app.log"
SELFTEST_LOG="$BUILD_DIR/selftest.log"
rm -f "$XCTEST_LOG" "$BUILD_LOG" "$SELFTEST_LOG"

# ---------------------------------------------------------------- 0) App 构建
echo "==> [1/3] 编译 App target（swift build）"
build_exit=0
swift build --package-path "$ROOT" --disable-sandbox ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} \
    > "$BUILD_LOG" 2>&1 || build_exit=$?
if [ "$build_exit" -eq 0 ]; then
    echo "    App target 编译通过"
else
    echo "    App target 编译失败（详见 $BUILD_LOG）"
    sed -n '1,20p' "$BUILD_LOG" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 1) XCTest
echo "==> [2/3] XCTest（swift test --disable-sandbox）"
xctest_exit=0
swift test --package-path "$ROOT" --disable-sandbox ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} \
    > "$XCTEST_LOG" 2>&1 || xctest_exit=$?

# 数量解析与退出码解耦：失败也保留真实计数（不清零、不写 0）
xctest_line="$(grep -E "Executed [0-9]+ tests?" "$XCTEST_LOG" | tail -1)"
xctest_count="?"
xctest_failures="?"
if [ -n "$xctest_line" ]; then
    xctest_count="$(printf '%s' "$xctest_line" | sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p')"
    xctest_failures="$(printf '%s' "$xctest_line" | sed -nE 's/.*with ([0-9]+) failures?.*/\1/p')"
    echo "    XCTest：${xctest_count} 个用例，${xctest_failures} 失败"
else
    xctest_failures="?"
    echo "    XCTest：未产生结果（exit=${xctest_exit}，详见 $XCTEST_LOG）"
    sed -n '1,20p' "$XCTEST_LOG" | sed 's/^/    /'
fi
if [ "$xctest_exit" -ne 0 ] && [ "$xctest_failures" = "0" ]; then
    # 有退出码但没解析到失败数（编译失败 / 崩溃）——不能当成 0 失败
    echo "    XCTest：退出码非零（${xctest_exit}），但未解析到失败计数，按失败处理"
    xctest_failures="未知"
fi

# ---------------------------------------------------------------- 2) SelfTest
echo "==> [3/3] SelfTest（Tools/SelfTest，独立的断言级复核）"
selftest_exit=0
swiftc -emit-module -emit-library -static -module-name MoleLiteCore \
    -target "$TARGET" -sdk "$SDK" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -O \
    -o "$BUILD_DIR/libMoleLiteCore.a" \
    -emit-module-path "$BUILD_DIR/MoleLiteCore.swiftmodule" \
    "$ROOT"/Sources/MoleLiteCore/Models/*.swift \
    "$ROOT"/Sources/MoleLiteCore/Services/*.swift > "$SELFTEST_LOG" 2>&1 || selftest_exit=$?

if [ "$selftest_exit" -eq 0 ]; then
    swiftc -module-name SelfTest \
        -I "$BUILD_DIR" -L "$BUILD_DIR" -lMoleLiteCore \
        -target "$TARGET" -sdk "$SDK" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        "$ROOT"/Tools/SelfTest/main.swift -o "$BUILD_DIR/selftest" >> "$SELFTEST_LOG" 2>&1 || selftest_exit=$?
fi

if [ "$selftest_exit" -eq 0 ]; then
    "$BUILD_DIR/selftest" >> "$SELFTEST_LOG" 2>&1 || selftest_exit=$?
fi

selftest_line="$(grep -E "结果：[0-9]+ 通过，[0-9]+ 失败" "$SELFTEST_LOG" | tail -1)"
if [ -n "$selftest_line" ]; then
    echo "    SelfTest：$selftest_line"
else
    echo "    SelfTest：未产生结果（exit=${selftest_exit}，详见 $SELFTEST_LOG）"
fi

# ---------------------------------------------------------------- 汇总
echo ""
echo "==> 测试汇总"
echo "    App 构建      ：$([ "$build_exit" -eq 0 ] && echo "通过" || echo "失败（exit=${build_exit}）")"
echo "    XCTest 用例   ：${xctest_count} 个 / ${xctest_failures} 失败（${XCTEST_LOG}）"
echo "    SelfTest 断言 ：${selftest_line:-无结果（exit=${selftest_exit}）}（${SELFTEST_LOG}）"

FAILED=0
[ "$build_exit" -ne 0 ] && FAILED=1
[ "$xctest_exit" -ne 0 ] && FAILED=1
[ "$xctest_failures" != "0" ] && [ "$xctest_failures" != "?" ] && FAILED=1
if [ "$xctest_count" = "?" ] && [ "$xctest_exit" -eq 0 ]; then
    # 进程成功但没有解析到用例数，不能当成通过
    FAILED=1
fi
[ "$selftest_exit" -ne 0 ] && FAILED=1
if [ -z "$selftest_line" ] && [ "$selftest_exit" -eq 0 ]; then
    # 进程成功但没有解析到结果，不能当成通过
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    echo "==> 存在失败：App 构建 exit=${build_exit}，XCTest exit=${xctest_exit}，SelfTest exit=${selftest_exit}"
    exit 1
fi

echo "==> App 构建与两套测试全部通过"
