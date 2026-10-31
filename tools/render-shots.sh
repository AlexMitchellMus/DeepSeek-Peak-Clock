#!/usr/bin/env bash
# Builds the offscreen SwiftUI renderer and writes artifacts/screens/native-*.png
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"
export TMPDIR="$ROOT/.tmp/hc"
export CLANG_MODULE_CACHE_PATH="$ROOT/.tmp/mc"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
cd "$ROOT"
swiftc -O -parse-as-library \
  -target arm64-apple-macosx14.0 -sdk "$SDK" \
  native/DeepSeekCore/Sources/DeepSeekCore/*.swift \
  native/Shared/*.swift \
  tools/RenderShots/main.swift \
  -o .tmp/render-shots
./.tmp/render-shots
