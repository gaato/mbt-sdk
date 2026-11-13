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

# Formatting and interfaces are the rendering of the toolchain moonbit-version
# pins, which CI runs. The canary runs these gates on newer toolchains too,
# where the same code may render otherwise; that is news about the toolchain,
# so there the checks below report it instead of failing.
pinned=0
case "$(moon version --all)" in *"$(cat moonbit-version)"*) pinned=1 ;; esac
note() { echo "note: $* (this toolchain is not moonbit-version's)" >&2; }

# `moon fmt --check`. Off the pinned toolchain, a difference that only adds or
# drops a comma at the end of lines is a note: MoonBit's formatter after 0.10.20
# puts a trailing comma after the last item of a list it breaks over lines,
# where 0.10.20's removes it, and an enum constructor whose payload is too
# long for one line (generated code, ChatEvent::ToolCallDelta) has no form
# both accept. Any other difference fails.
fmt_check() {
  echo "+ moon fmt --check $*"
  local out
  out=$(moon fmt --check "$@" 2>&1) && return 0
  if [ "$pinned" = 1 ]; then echo "$out"; return 1; fi
  local plain lines removed added
  plain=$(echo "$out" | sed 's/\x1b\[[0-9;]*m//g')
  lines=$(echo "$plain" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) ' || true)
  removed=$(echo "$lines" | sed -n 's/^-//p' | sed 's/,$//' | sort)
  added=$(echo "$lines" | sed -n 's/^+//p' | sed 's/,$//' | sort)
  if [ -n "$lines" ] && [ "$removed" = "$added" ]; then
    note "moon fmt only moves trailing commas in $(echo "$plain" | grep -c '^diff ' || true) files"
    return 0
  fi
  echo "$out"; return 1
}

# Every published module's CHANGELOG has [Unreleased] and a heading for its version.
run scripts/release.sh check
# The registry index, which the .mbtx scripts need to resolve their imports.
run moon update
# Every enforced limit in RESOURCE_BOUNDS.md names tests that exist.
run moon run scripts/bounds_check.mbtx
# READMEs and doc comments follow the rules shared by every gaato MoonBit repository.
run moon run scripts/docs_audit.mbtx --self-test
for m in jsonrpc openai anthropic codex-protocol github conformance; do
  for t in "${all_targets[@]}"; do run moon -C "$m" check --deny-warn --target "$t"; done
done
for m in fixtures/gen/badhttp fixtures/gen/petstore3; do
  for t in "${all_targets[@]}"; do run moon -C "$m" check --deny-warn --target "$t"; done
done
for m in jsonrpc-async codex-app-server runtime-tests; do
  for t in "${io_targets[@]}"; do run moon -C "$m" check --deny-warn --target "$t"; done
done

# Portable modules also support moonrun Wasm; the runtime adapters stay on
# native and JS. Select local packages so unpublished dependency workspaces
# remain read-only, and opt-in network suites never execute in ordinary gates.
offline_packages=(jsonrpc/src jsonrpc-async/src codex-app-server/src codex-app-server/src/examples/initialize codex-protocol/src/gen codex-protocol/src/tests openai/src openai/src/gen anthropic/src anthropic/src/gen github/src github/src/gen conformance/src/harness conformance/src/jsonrpc conformance/src/sse conformance/src/url conformance/src/cookie fixtures/gen/badhttp/src fixtures/gen/petstore3/src runtime-tests/src/sdk_mock runtime-tests/src/openai runtime-tests/src/anthropic runtime-tests/src/github runtime-tests/src/loopback runtime-tests/src/badhttp_replay runtime-tests/src/async-clock)
local_packages=("${offline_packages[@]}" runtime-tests/src/live runtime-tests/src/badhttp)
run timeout 120 moon test "${offline_packages[@]}" --target wasm-gc
[ "$js" = 1 ] && run timeout 120 moon test "${offline_packages[@]}" --target js
[ "$native_tests" = 1 ] && run timeout 120 moon test "${offline_packages[@]}" --target native
run moon check "${local_packages[@]}" --target wasm --deny-warn
run timeout 120 moon test "${offline_packages[@]}" --target wasm

py=(uv run --with pyyaml --with jsonpath-rfc9535 python); [ -x .venv/bin/python ] && py=(.venv/bin/python)
run "${py[@]}" -m unittest discover -s tools/gen/tests -v
# The generators format their output with the running moonfmt, so off the
# pinned toolchain the trailing commas above make their output differ (exit
# status 1); any other failure still fails.
if [ "$pinned" = 1 ]; then
  run scripts/generate.sh --check
else
  status=0; run scripts/generate.sh --check || status=$?
  [ "$status" = 0 ] || [ "$status" = 1 ] || exit "$status"
  [ "$status" = 0 ] || note "generated files differ from this toolchain's formatting"
fi
fmt_check "${local_packages[@]}"
run moon info "${local_packages[@]}"
run "${py[@]}" tools/gen/census.py specs/badhttp/openapi.json badhttp --expect-zero
run "${py[@]}" tools/gen/census.py specs/petstore3/openapi.json petstore3 --expect-zero
run "${py[@]}" tools/gen/census.py openai/spec/openai.yaml openai --derive-operation-ids --overlay openai/overlays/fix.yaml --overlay openai/overlays/moonbit.yaml --expect-zero
# Anthropic currently ships four operations; the full upstream spec includes unsupported beta APIs.
run "${py[@]}" tools/gen/census.py anthropic/spec/anthropic.json anthropic --ops messages_post,messages_count_tokens_post,models_list,models_get --overlay anthropic/overlays/moonbit.yaml --expect-zero
# GitHub generates every operation in the document, so the census covers all of them.
run "${py[@]}" tools/gen/census.py github/spec/api.github.com.2022-11-28.yaml github --overlay github/overlays/fix.yaml --overlay github/overlays/moonbit.yaml --expect-zero
# Only meaningful in CI: in a jj working copy `git diff` compares against the parent change,
# so uncommitted edits would look stale. Set MBT_SDK_CHECK_MBTI=1 to enforce locally.
if [ "${CI:-}" = true ] || [ "${MBT_SDK_CHECK_MBTI:-}" = 1 ]; then
  if [ "$pinned" = 1 ]; then
    git diff --exit-code -- '*.mbti' || { echo "pkg.generated.mbti is stale: run 'moon info' and commit" >&2; exit 1; }
  else
    git diff --exit-code -- '*.mbti' || note "'moon info' renders the interfaces above differently"
  fi
fi
echo "gates: OK"
