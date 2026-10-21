// The transport adapter, as its own module, because in MoonBit an import
// applies to the whole module: `moonbitlang/async` must not land in the
// dependency graph of `gaato/http`.

name = "gaato/http-async"

version = "0.4.2"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/gaato/mbt-sdk"

keywords = [ "http", "transport", "async", "client" ]

description = "gaato/http Transport over moonbitlang/async. Native, JS, and moonrun Wasm targets."

source = "src"

preferred_target = "native"

import {
  "gaato/http@0.4.1",
  "moonbitlang/async@0.22.5",
  "gaato/codec_bytes@0.1.1",
  "gaato/deflate@0.1.0",
  "gaato/brotli@0.4.1",
  "gaato/zstd@0.3.1",
}
