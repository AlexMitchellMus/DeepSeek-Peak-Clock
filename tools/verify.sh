#!/usr/bin/env bash
# Runs every check the project claims in SPEC.md §7.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
run() {
  printf '\n\033[1m▸ %s\033[0m\n' "$1"
  shift
  if "$@"; then printf '  ok\n'; else printf '  FAILED\n'; fail=1; fi
}

run "spec vectors are in sync with the reference clock" node spec/vectors.mjs --check
run "collector unit tests (offline)" node --test collector/
run "Swift core tests" bash -c '
  export TMPDIR="$PWD/.tmp/hc" CLANG_MODULE_CACHE_PATH="$PWD/.tmp/mc"
  mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
  cd native/DeepSeekCore
  swift test --disable-sandbox --cache-path ../../.tmp/cc --scratch-path ../../.tmp/cc 2>&1 | tail -3'

run "native app + widget extension build" bash -c '
  export TMPDIR="$PWD/.tmp/hc" CLANG_MODULE_CACHE_PATH="$PWD/.tmp/mc"
  xcodebuild -project native/DeepSeekTracker.xcodeproj -scheme DeepSeekTracker \
    -configuration Debug -derivedDataPath "$PWD/.tmp/dd" build 2>&1 | tail -2'

printf '\n'
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "some checks failed"; fi
exit "$fail"
