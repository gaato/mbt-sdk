#!/usr/bin/env bash
# Prints the current all-operation generator census for vendored specs.
set -euo pipefail
cd "$(dirname "$0")/.."
py=(uv run --with pyyaml --with jsonpath-rfc9535 python)
[ -x .venv/bin/python ] && py=(.venv/bin/python)
registered=$("${py[@]}" tools/sdks.py list --generator openapi)
mapfile -t sdks <<< "$registered"
specs=()
for sdk in "${sdks[@]}"; do specs+=("$("${py[@]}" tools/sdks.py get "$sdk" spec_file)"); done
# Census-only specs (currently openrouter) have no generated module to register.
for spec in specs/*/openapi.json; do
  registered=0
  for known in "${specs[@]}"; do [ "$spec" != "$known" ] || registered=1; done
  [ "$registered" = 0 ] || continue
  "${py[@]}" tools/gen/census.py "$spec" "$(basename "$(dirname "$spec")")"
done
for i in "${!sdks[@]}"; do
  args=$("${py[@]}" tools/sdks.py get "${sdks[$i]}" report_census_args)
  flags=(); [ -z "$args" ] || mapfile -t flags <<< "$args"
  "${py[@]}" tools/gen/census.py "${specs[$i]}" "${sdks[$i]}" "${flags[@]}"
done
