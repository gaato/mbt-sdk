#!/usr/bin/env bash
# Applies the overlays and (re)generates openai/src/gen. Pass --check to verify without writing.
set -euo pipefail
cd "$(dirname "$0")/.."
py=(uv run); [ -x .venv/bin/python ] && py=(.venv/bin/python)
"${py[@]}" tools/apply_overlay.py openai/spec/openai.yaml openai/spec/openai.patched.json openai/overlays/*.yaml
overlays=(); for o in openai/overlays/*.yaml; do overlays+=(--overlay "$o"); done
"${py[@]}" tools/gen/main.py --spec openai/spec/openai.yaml "${overlays[@]}" \
  --out openai/src/gen --package gaato/openai/gen "$@"
