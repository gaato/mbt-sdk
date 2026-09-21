// No `import` block on purpose: this module depends on nothing but
// moonbitlang/core, so it checks on wasm-gc, wasm, js and native. Anything
// that needs a socket or an async runtime lives in a sibling module -- see
// ../moon.work.

name = "gaato/http"

version = "0.1.0"

license = "Apache-2.0"

keywords = [ "http", "sans-io", "transport", "sse", "client" ]

description = "Sans-IO HTTP vocabulary for MoonBit SDKs: request/response types, a Transport trait, an incremental SSE parser and a scripted fake transport. No dependencies; runs on every backend."

source = "src"

preferred_target = "wasm-gc"
