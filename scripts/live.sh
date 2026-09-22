#!/usr/bin/env bash
# Opt-in live tests against real LLM APIs. Reads OPENAI_API_KEY / ANTHROPIC_API_KEY /
# OPENROUTER_API_KEY from the environment, or from ~/.config/mbt-sdk/env (KEY=value lines,
# mode 600) when present.
# Tests skip a provider whose key is absent. Costs: a handful of tiny requests per provider;
# the OpenRouter tests use only :free models.
set -euo pipefail
cd "$(dirname "$0")/.."
env_file="${MBT_SDK_ENV:-$HOME/.config/mbt-sdk/env}"
if [ -f "$env_file" ]; then
  set -a; # shellcheck disable=SC1090
  . "$env_file"; set +a
fi
export OPENAI_API_KEY="${OPENAI_API_KEY:-}" ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
exec timeout 900 moon -C runtime-tests test --target native -p gaato/mbt-sdk-runtime-tests/live "$@"
