// Unpublished SDK integration tests. Portable suites use http/driver;
// socket and live suites use core/async in target-specific packages.

name = "gaato/mbt-sdk-runtime-tests"

version = "0.0.0"

private = true

license = "Apache-2.0"

source = "src"

preferred_target = "native"

import {
  "gaato/mttp@0.3.0",
  "gaato/mttp_core@0.1.0",
  "gaato/openai@0.9.0",
  "gaato/anthropic@0.17.0",
  "gaato/github@0.23.0",
  "gaato/fixture-badhttp@0.0.0",
}
