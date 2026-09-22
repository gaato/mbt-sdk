#!/usr/bin/env bash
# Applies overlays and regenerates OpenAI, Anthropic and the all-operation fixtures.
# Pass --check to verify without writing.
set -euo pipefail
cd "$(dirname "$0")/.."
py=(uv run --with pyyaml --with jsonpath-rfc9535 python); [ -x .venv/bin/python ] && py=(.venv/bin/python)
"${py[@]}" tools/apply_overlay.py openai/spec/openai.yaml openai/spec/openai.patched.json openai/overlays/*.yaml
overlays=(); for o in openai/overlays/*.yaml; do overlays+=(--overlay "$o"); done
"${py[@]}" tools/gen/main.py --spec openai/spec/openai.yaml "${overlays[@]}" \
  --out openai/src/gen --package gaato/openai/gen "$@"
"${py[@]}" tools/apply_overlay.py anthropic/spec/anthropic.json anthropic/spec/anthropic.patched.json anthropic/overlays/*.yaml
overlays=(); for o in anthropic/overlays/*.yaml; do overlays+=(--overlay "$o"); done
"${py[@]}" tools/gen/main.py --spec anthropic/spec/anthropic.json "${overlays[@]}" \
  --out anthropic/src/gen --package gaato/anthropic/gen "$@"
"${py[@]}" tools/gen/main.py --spec specs/badhttp/openapi.json \
  --include-all --derive-operation-ids --out fixtures/gen/badhttp/src \
  --package gaato/fixture-badhttp "$@"
"${py[@]}" tools/gen/main.py --spec specs/petstore3/openapi.json \
  --include-all --derive-operation-ids --out fixtures/gen/petstore3/src \
  --package gaato/fixture-petstore3 "$@"
"${py[@]}" tools/gen/codex.py "$@"
