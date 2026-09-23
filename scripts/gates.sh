#!/usr/bin/env bash
# Runs the repository validation suite. Usage: scripts/gates.sh [--no-js] [--no-native-tests]
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
for m in http jsonrpc sdk-runtime openai anthropic codex-protocol github; do
  for t in "${all_targets[@]}"; do run moon -C "$m" check --deny-warn --target "$t"; done
done
for m in fixtures/gen/badhttp fixtures/gen/petstore3; do
  for t in "${all_targets[@]}"; do run moon -C "$m" check --deny-warn --target "$t"; done
done
for m in http-async jsonrpc-async codex-app-server runtime-tests; do
  for t in "${io_targets[@]}"; do run moon -C "$m" check --deny-warn --target "$t"; done
done

# In a moon.work workspace `moon -C <member> test` runs every member that supports the target.
run timeout 120 moon -C runtime-tests test --target wasm-gc
[ "$js" = 1 ] && run timeout 120 moon -C runtime-tests test --target js
[ "$native_tests" = 1 ] && run timeout 120 moon -C runtime-tests test --target native

py=(uv run --with pyyaml --with jsonpath-rfc9535 python); [ -x .venv/bin/python ] && py=(.venv/bin/python)
run "${py[@]}" -m unittest discover -s tools/gen/tests -v
run scripts/generate.sh --check
run moon fmt --check
run moon info
run "${py[@]}" tools/gen/census.py specs/badhttp/openapi.json badhttp --expect-zero
run "${py[@]}" tools/gen/census.py specs/petstore3/openapi.json petstore3 --expect-zero
run "${py[@]}" tools/gen/census.py openai/spec/openai.yaml openai --derive-operation-ids --overlay openai/overlays/fix.yaml --overlay openai/overlays/moonbit.yaml --expect-zero
# Anthropic currently ships four operations; the full upstream spec includes unsupported beta APIs.
run "${py[@]}" tools/gen/census.py anthropic/spec/anthropic.json anthropic --ops messages_post,messages_count_tokens_post,models_list,models_get --overlay anthropic/overlays/moonbit.yaml --expect-zero
# GitHub generates every operation in the document, so the census covers all 1,221.
run "${py[@]}" tools/gen/census.py github/spec/api.github.com.2022-11-28.yaml github --overlay github/overlays/fix.yaml --overlay github/overlays/moonbit.yaml --expect-zero
# Only meaningful in CI: in a jj working copy `git diff` compares against the parent change,
# so uncommitted edits would look stale. Set MBT_SDK_CHECK_MBTI=1 to enforce locally.
if [ "${CI:-}" = true ] || [ "${MBT_SDK_CHECK_MBTI:-}" = 1 ]; then
  git diff --exit-code -- '*.mbti' || { echo "pkg.generated.mbti is stale: run 'moon info' and commit" >&2; exit 1; }
fi
echo "gates: OK"
