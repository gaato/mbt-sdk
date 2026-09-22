#!/usr/bin/env bash
# Starts the local OpenAI-/Anthropic-compatible servers the live tests can target,
# CPU-only and key-free: Ollama with a ~500M tools-capable model, and a LiteLLM proxy in front
# of it that speaks Anthropic /v1/messages. Prints the env vars to export.
# Usage: scripts/compat-servers.sh [start|stop|env]
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL="${COMPAT_MODEL:-qwen2.5:0.5b}"
# smollm2 rejects the tools parameter. Keep a small, non-thinking model that
# accepts tools even when it does not reliably choose to call one.
# Both servers are deliberately unpinned: a new Ollama/LiteLLM release breaking
# these tests is exactly the drift this repo exists to catch (see README.md).
case "${1:-start}" in
  start)
    if ! curl -sf -m 2 http://127.0.0.1:11434/api/version >/dev/null; then
      (ollama serve >"${RUNNER_TEMP:-/tmp}/ollama.log" 2>&1 &)
      for _ in $(seq 1 30); do curl -sf -m 2 http://127.0.0.1:11434/api/version >/dev/null && break; sleep 1; done
    fi
    ollama pull "$MODEL" >"${RUNNER_TEMP:-/tmp}/ollama-pull.log" 2>&1
    if ! curl -sf -m 2 http://127.0.0.1:4000/health/liveliness >/dev/null; then
      (uvx --from 'litellm[proxy]' litellm --config scripts/litellm.yaml --host 127.0.0.1 --port 4000 >"${RUNNER_TEMP:-/tmp}/litellm.log" 2>&1 &)
      for _ in $(seq 1 90); do curl -sf -m 2 http://127.0.0.1:4000/health/liveliness >/dev/null && break; sleep 2; done
    fi
    curl -sf -m 2 http://127.0.0.1:4000/health/liveliness >/dev/null || { echo "litellm did not start" >&2; exit 1; }
    ;&
  env)
    cat <<ENV
OPENAI_COMPAT_BASE_URL=http://127.0.0.1:11434/v1
OPENAI_COMPAT_MODEL=$MODEL
ANTHROPIC_COMPAT_BASE_URL=http://127.0.0.1:4000/v1
ANTHROPIC_COMPAT_MODEL=tiny
ANTHROPIC_COMPAT_API_KEY=sk-local-compat
ENV
    ;;
  stop)
    pkill -f 'litellm --config scripts/litellm.yaml' || true
    ;;
  *) echo "usage: $0 [start|stop|env]" >&2; exit 2 ;;
esac
