// Depends on the sans-IO vocabulary and the runtime only. The caller supplies a
// Transport and a Clock, so this module checks on every backend.

name = "gaato/anthropic"

version = "0.15.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mbt-sdk"

keywords = [ "anthropic", "llm", "sdk", "messages" ]

description = "Thin Anthropic Messages API client for MoonBit built on gaato/http and gaato/mttp."

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/http@0.6.0",
  "gaato/mttp@0.1.0",
}
