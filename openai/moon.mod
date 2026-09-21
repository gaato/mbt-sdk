// Depends on the sans-IO vocabulary and the runtime only. The caller supplies a
// Transport and a Clock (for example from gaato/http-async), so this module
// checks on every backend.

name = "gaato/openai"

version = "0.1.0"

license = "Apache-2.0"

keywords = [ "openai", "llm", "sdk", "responses", "embeddings" ]

description = "Thin OpenAI API client for MoonBit built on gaato/http and gaato/sdk-runtime: models, embeddings, responses (buffered and streaming)."

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/http@0.1.0",
  "gaato/sdk-runtime@0.1.0",
}
