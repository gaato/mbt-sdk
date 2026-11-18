#!/usr/bin/env bash
# Opt-in live tests against real LLM, GitHub, and read-only Cloudflare DNS APIs.
# Reads settings from the environment or ~/.config/moonbit-sdks/env
# (KEY=value lines, mode 600) when present. See docs/live-tests.md.
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
export GEMINI_API_KEY="${GEMINI_API_KEY:-}" VOYAGE_API_KEY="${VOYAGE_API_KEY:-}"
export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
exec timeout 900 moon test --target native \
  runtime-tests/src/live runtime-tests/src/gemini_live runtime-tests/src/cloudflare_dns_live "$@"
