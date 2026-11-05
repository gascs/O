#!/usr/bin/env bash
# 同时运行两套测试，并分别报告真实数量：
#   1) XCTest（swift test）      —— 按「测试用例」计数
#   2) Tools/SelfTest            —— 按「断言项」计数，不依赖 XCTest
#
# 两套覆盖同一批 Core 行为，只是计数粒度不同：
# SelfTest 的 204 是断言条数，XCTest 的 78 是用例数（一个用例内可含多条断言）。
# 因此不再「优先 swift test 提前退出」，而是两套都跑、都报数。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/.build/app"
SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macos13.0"
mkdir -p "$BUILD_DIR"

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
SELFTEST_LOG="$BUILD_DIR/selftest.log"
rm -f "$XCTEST_LOG" "$SELFTEST_LOG"

# ---------------------------------------------------------------- 1) XCTest
echo "==> [1/2] XCTest（swift test）"
xctest_exit=0
swift test --package-path "$ROOT" > "$XCTEST_LOG" 2>&1 || xctest_exit=$?

xctest_line="$(grep -E "Executed [0-9]+ tests?" "$XCTEST_LOG" | tail -1)"
if [ "$xctest_exit" -eq 0 ] && [ -n "$xctest_line" ]; then
    xctest_count="$(printf '%s' "$xctest_line" | sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p')"
    xctest_failures="$(printf '%s' "$xctest_line" | sed -nE 's/.*with ([0-9]+) failures?.*/\1/p')"
    echo "    XCTest：${xctest_count:-?} 个用例，${xctest_failures:-?} 失败"
else
    xctest_count="0"
    echo "    XCTest：无法执行或未通过（详见 $XCTEST_LOG）"
fi

# ---------------------------------------------------------------- 2) SelfTest
echo "==> [2/2] SelfTest（Tools/SelfTest，独立的断言级复核）"
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
    echo "    SelfTest：未产生结果（详见 ${SELFTEST_LOG}）"
fi

# ---------------------------------------------------------------- 汇总
echo ""
echo "==> 测试汇总"
echo "    XCTest 用例：${xctest_count:-0} 通过 / ${xctest_failures:-0} 失败（${XCTEST_LOG}）"
echo "    SelfTest 断言：${selftest_line:-无结果}（${SELFTEST_LOG}）"

if [ "$xctest_exit" -ne 0 ] || [ "$selftest_exit" -ne 0 ]; then
    echo "==> 存在失败：XCTest exit=${xctest_exit}，SelfTest exit=${selftest_exit}"
    exit 1
fi

echo "==> 两套测试全部通过"
