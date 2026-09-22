// Unpublished. Executes the async behaviour of gaato/sdk-runtime: a module
// without moonbitlang/async cannot run `async test`, and even a test-only
// import would land in that module's dependency graph.

name = "gaato/mbt-sdk-runtime-tests"

version = "0.0.0"

license = "Apache-2.0"

source = "src"

preferred_target = "native"

import {
  "gaato/http@0.1.0",
  "gaato/http-async@0.1.0",
  "gaato/sdk-runtime@0.1.0",
  "gaato/openai@0.1.0",
  "gaato/fixture-badhttp@0.0.0",
  "moonbitlang/async@0.22.1",
}
