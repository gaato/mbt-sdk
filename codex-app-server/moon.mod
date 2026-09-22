name = "gaato/codex-app-server"

version = "0.1.0"

license = "Apache-2.0"

description = "Codex app-server client over bidirectional JSON-RPC"

source = "src"

preferred_target = "native"

supported_targets = "js + native"

import {
  "gaato/codex-protocol@0.1.0",
  "gaato/jsonrpc@0.1.0",
  "gaato/jsonrpc-async@0.1.0",
  "moonbitlang/async@0.22.1",
}
