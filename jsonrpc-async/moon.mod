// The transport, as its own module, because in MoonBit an import applies to
// the whole module: `moonbitlang/async` must not land in the dependency graph
// of `gaato/jsonrpc`.

name = "gaato/jsonrpc-async"

version = "0.1.0"

license = "Apache-2.0"

repository = "https://github.com/gaato/mbt-sdk"

keywords = [ "jsonrpc", "json-rpc", "stdio", "async", "acp" ]

description = "Bidirectional JSON-RPC 2.0 connections over moonbitlang/async: any Reader/Writer pair, and child processes over stdio (native). Built on gaato/jsonrpc."

source = "src"

preferred_target = "native"

import {
  "gaato/jsonrpc@0.1.0",
  "moonbitlang/async@0.22.4",
}
