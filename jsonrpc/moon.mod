// No `import` block on purpose: this module depends on nothing but
// moonbitlang/core, so it checks on wasm-gc, wasm, js and native. The stdio
// and child-process transport lives in ../jsonrpc-async (imports are
// module-wide in MoonBit).

name = "gaato/jsonrpc"

version = "0.1.0"

license = "Apache-2.0"

keywords = [ "jsonrpc", "json-rpc", "sans-io", "ndjson", "acp" ]

description = "Sans-IO JSON-RPC 2.0 vocabulary for MoonBit SDKs: message and error types, strict and bare envelopes, NDJSON encoding and an incremental line framer. No dependencies; runs on every backend."

source = "src"

preferred_target = "wasm-gc"
