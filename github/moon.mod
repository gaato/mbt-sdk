// Depends on the sans-IO vocabulary and the runtime only. The caller supplies a
// Backend and a Clock, so this module checks on every backend.

name = "gaato/github"

version = "0.18.0"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mbt-sdk"

keywords = [ "github", "rest", "graphql", "sdk", "openapi" ]

description = "Thin GitHub API client for MoonBit built on gaato/mttp: the whole REST API generated, plus a GraphQL passthrough."

source = "src"

preferred_target = "wasm-gc"

import {
  "gaato/mttp@0.1.0",
}
