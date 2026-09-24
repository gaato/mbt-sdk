// Depends on gaato/http only. No async runtime: time is injected through the
// `Clock` trait so retry and rate-limit logic is testable with a fake clock and
// the module checks on every backend.

name = "gaato/sdk-runtime"

version = "0.2.1"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mbt-sdk"

keywords = [ "sdk", "http", "retry", "rate-limit", "pagination", "json" ]

description = "API-agnostic client runtime for MoonBit SDKs: error taxonomy, Retry-After and backoff, tri-state JSON fields, open enums. Built on gaato/http; no async runtime dependency."

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/http@0.1.0",
}
