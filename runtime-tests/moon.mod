// Unpublished SDK integration tests. Portable suites use http/driver;
// socket and live suites use core/async in target-specific packages.

name = "gaato/mbt-sdk-runtime-tests"

version = "0.0.0"

private = true

license = "Apache-2.0"

source = "src"

preferred_target = "native"

import {
  "gaato/http@0.6.0",
  "gaato/http-async@0.6.0",
  "gaato/mttp@0.1.0",
  "gaato/openai@0.7.0",
  "gaato/anthropic@0.15.0",
  "gaato/github@0.19.0",
  "gaato/fixture-badhttp@0.0.0",
}
