// The transport adapter, as its own module, because in MoonBit an import
// applies to the whole module: `moonbitlang/async` must not land in the
// dependency graph of `gaato/http`.

name = "gaato/http-async"

version = "0.1.0"

license = "Apache-2.0"

keywords = [ "http", "transport", "async", "client" ]

description = "gaato/http Transport over moonbitlang/async. Native and js targets."

source = "src"

preferred_target = "native"

import {
  "gaato/http@0.1.0",
  "moonbitlang/async@0.22.1",
}
