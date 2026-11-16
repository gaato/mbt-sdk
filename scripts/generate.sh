#!/usr/bin/env bash
# Regenerates ledger entries; optional SDK names restrict the run. --check never writes.
set -euo pipefail
cd "$(dirname "$0")/.."
py=(uv run --with pyyaml --with jsonpath-rfc9535 python); [ -x .venv/bin/python ] && py=(.venv/bin/python)
# Validate before launching any generators, including for a selected run.
registered=$("${py[@]}" tools/sdks.py list)
sdks=(); flags=()
for arg in "$@"; do
  case "$arg" in
    --check) flags+=("$arg") ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) "${py[@]}" tools/sdks.py get "$arg" dir >/dev/null; sdks+=("$arg") ;;
  esac
done
[ "${#sdks[@]}" -gt 0 ] || mapfile -t sdks <<< "$registered"
# A difference does not stop other generators; a generation failure does.
status=0
gen() { local s=0; echo "+ ${py[*]} $*"; "${py[@]}" "$@" || s=$?; [ "$s" -le 1 ] || exit "$s"; [ "$s" -le "$status" ] || status=$s; }
get() { "${py[@]}" tools/sdks.py get "$sdk" "$1"; }
for sdk in "${sdks[@]}"; do
  args=(--spec "$(get spec_file)" --out "$(get out)")
  case "$(get generator)" in
    custom)
      gen "$(get command)" "${args[@]}" "${flags[@]}"
      continue
      ;;
    openapi|discovery) ;;
  esac
  args+=(--package "$(get package)" --sdk "$sdk")
  [ "$(get client_layer)" = false ] || args+=(--client-sdk "$sdk")
  [ "$(get include_all)" = false ] || args+=(--include-all)
  [ "$(get derive_operation_ids)" = false ] || args+=(--derive-operation-ids)
  for overlay in "$(get dir)"/overlays/*.yaml; do
    [ ! -f "$overlay" ] || args+=(--overlay "$overlay")
  done
  gen tools/gen/main.py "${args[@]}" "${flags[@]}"
done
exit "$status"
