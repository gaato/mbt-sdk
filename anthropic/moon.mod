// Depends on the sans-IO vocabulary and the runtime only. The caller supplies a
// Transport and a Clock, so this module checks on every backend.

name = "gaato/anthropic"

version = "0.12.1"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mbt-sdk"

keywords = [ "anthropic", "llm", "sdk", "messages" ]

description = "Thin Anthropic Messages API client for MoonBit built on gaato/http and gaato/sdk-runtime."

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/http@0.4.1",
  "gaato/sdk-runtime@0.7.0",
}
