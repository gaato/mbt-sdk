#!/usr/bin/env bash
# Opt-in live tests against real LLM APIs and the GitHub REST API. Reads
# OPENAI_API_KEY / ANTHROPIC_API_KEY / OPENROUTER_API_KEY / MBT_SDK_GITHUB_TOKEN from the
# environment, plus DEEPSEEK_API_KEY / DASHSCOPE_API_KEY / ZAI_API_KEY / MOONSHOT_API_KEY,
# or from ~/.config/moonbit-sdks/env (KEY=value lines, mode 600) when present.
# The GitHub switch is MBT_SDK_GITHUB_TOKEN rather than GITHUB_TOKEN, which GitHub Actions
# injects into every job.
# Tests skip a provider whose key is absent. Costs: a handful of tiny requests per provider;
# the OpenRouter tests use only :free models.
set -euo pipefail
cd "$(dirname "$0")/.."
env_file="${MBT_SDK_ENV:-$HOME/.config/moonbit-sdks/env}"
if [ -f "$env_file" ]; then
  set -a; # shellcheck disable=SC1090
  . "$env_file"; set +a
fi
export OPENAI_API_KEY="${OPENAI_API_KEY:-}" ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
export MBT_SDK_GITHUB_TOKEN="${MBT_SDK_GITHUB_TOKEN:-}"
export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}" DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY:-}"
export ZAI_API_KEY="${ZAI_API_KEY:-}" MOONSHOT_API_KEY="${MOONSHOT_API_KEY:-}"
exec timeout 900 moon -C runtime-tests test --target native -p gaato/moonbit-sdks-runtime-tests/live "$@"
