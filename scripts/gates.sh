#!/usr/bin/env bash
# Runs the gate list from AGENTS.md. Usage: scripts/gates.sh [--no-js] [--no-native-tests]
# --no-native-tests skips native test runs (they open loopback sockets, which some sandboxes forbid).
set -euo pipefail
cd "$(dirname "$0")/.."

js=1; native_tests=1
for arg in "$@"; do
  case "$arg" in
    --no-js) js=0 ;;
    --no-native-tests) native_tests=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

all_targets=(wasm-gc native); [ "$js" = 1 ] && all_targets+=(js)
io_targets=(native); [ "$js" = 1 ] && io_targets+=(js)

run() { echo "+ $*"; "$@"; }

run moon update
for m in http sdk-runtime openai; do
  for t in "${all_targets[@]}"; do run moon -C "$m" check --deny-warn --target "$t"; done
done
for m in http-async runtime-tests; do
  for t in "${io_targets[@]}"; do run moon -C "$m" check --deny-warn --target "$t"; done
done

# In a moon.work workspace `moon -C <member> test` runs every member that supports the target.
run timeout 600 moon -C runtime-tests test --target wasm-gc
[ "$js" = 1 ] && run timeout 600 moon -C runtime-tests test --target js
[ "$native_tests" = 1 ] && run timeout 600 moon -C runtime-tests test --target native

run moon fmt --check
run moon info
if command -v git >/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git diff --exit-code -- '*.mbti' || { echo "pkg.generated.mbti is stale: run 'moon info' and commit" >&2; exit 1; }
fi
echo "gates: OK"
