#!/usr/bin/env bash
#
# smoke-test.sh —— 不依赖界面和 Xcode 工程的纯逻辑回归测试
#
# 覆盖：消息解码、受保护目录判断、模型编解码往返。
# 本机 Xcode 许可受限时也能跑；GitHub Actions 里同样跑这一份。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${BUILD_DIR:-/tmp/iclick-smoke}"

SWIFTC="${SWIFTC:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
if [ ! -x "$SWIFTC" ]; then
    SWIFTC="$(command -v swiftc || true)"
fi
[ -n "$SWIFTC" ] || { echo "找不到 swiftc" >&2; exit 1; }

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$SDK" ]; then
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
[ -d "$SDK" ] || { echo "找不到 macOS SDK" >&2; exit 1; }

ARCH="$(uname -m)"
mkdir -p "$OUT"

echo "==> 编译 smoke tests ($ARCH, SDK $(basename "$SDK"))"
"$SWIFTC" -o "$OUT/smoke" -sdk "$SDK" -target "${ARCH}-apple-macos15.0" -swift-version 6 \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers \
    "$REPO_ROOT/Tests/main.swift" \
    "$REPO_ROOT/IClick/Shared/Constants.swift" \
    "$REPO_ROOT/IClick/Shared/AppLogger.swift" \
    "$REPO_ROOT/IClick/Shared/StringExtension.swift" \
    "$REPO_ROOT/IClick/Shared/Utils.swift" \
    "$REPO_ROOT/IClick/Shared/Messager.swift" \
    "$REPO_ROOT/IClick/Shared/DiagnosticLog.swift" \
    "$REPO_ROOT/IClick/Shared/MessageDeduplicator.swift" \
    "$REPO_ROOT/IClick/Model/RCBase.swift"

echo "==> 运行"
"$OUT/smoke"
