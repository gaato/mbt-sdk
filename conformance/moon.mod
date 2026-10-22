// Unpublished. Holds the sans-IO parsers of the workspace to the rules of
// CONTRACT.md through one harness, and checks them against third-party test
// data (see NOTICE), from outside their modules, as a consumer would.

name = "gaato/mbt-sdk-conformance"

version = "0.0.0"

private = true

license = "Apache-2.0"

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/http@0.5.0",
  "gaato/jsonrpc@0.1.0",
}
