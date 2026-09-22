#!/usr/bin/env bash
# Prints the current all-operation generator census for vendored specs.
set -euo pipefail
cd "$(dirname "$0")/.."

py=(uv run)
[ -x .venv/bin/python ] && py=(.venv/bin/python)

for spec in specs/*/openapi.json; do
  name="$(basename "$(dirname "$spec")")"
  "${py[@]}" tools/gen/census.py "$spec" "$name"
done
"${py[@]}" tools/gen/census.py openai/spec/openai.yaml openai
