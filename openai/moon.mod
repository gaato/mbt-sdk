// Depends on the sans-IO vocabulary and the runtime only. The caller supplies a
// Backend and a Clock (for example from gaato/http-async), so this module
// checks on every backend.

name = "gaato/openai"

version = "0.6.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mbt-sdk"

keywords = [ "openai", "llm", "sdk", "responses", "embeddings" ]

description = "Thin OpenAI API client for MoonBit built on gaato/mttp: models, embeddings, responses (buffered and streaming)."

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/mttp@0.1.0",
}
