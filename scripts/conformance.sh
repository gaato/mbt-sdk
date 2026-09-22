#!/usr/bin/env bash
# Opt-in conformance run against https://badhttp.dev (needs the network; ~30 requests).
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout 600 moon -C runtime-tests test --target native -p gaato/mbt-sdk-runtime-tests/badhttp "$@"
