#!/usr/bin/env bash
# Prints the current all-operation generator census for vendored specs.
set -euo pipefail
cd "$(dirname "$0")/.."

py=(uv run --with pyyaml --with jsonpath-rfc9535 python)
[ -x .venv/bin/python ] && py=(.venv/bin/python)

for spec in specs/*/openapi.json; do
  name="$(basename "$(dirname "$spec")")"
  "${py[@]}" tools/gen/census.py "$spec" "$name"
done
"${py[@]}" tools/gen/census.py openai/spec/openai.yaml openai --overlay openai/overlays/fix.yaml
"${py[@]}" tools/gen/census.py anthropic/spec/anthropic.json anthropic
"${py[@]}" tools/gen/census.py github/spec/api.github.com.2022-11-28.yaml github --overlay github/overlays/fix.yaml --overlay github/overlays/moonbit.yaml
