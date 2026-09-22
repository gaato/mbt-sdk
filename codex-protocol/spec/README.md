# Pinned Codex app-server schema

`schema.json` is the unmodified `codex_app_server_protocol.schemas.json` emitted
by **codex-cli 0.155.1**, without `--experimental`, on 2026-09-22.

SHA-256: `f1f3591667d8dcf77352c04be5d0667153e492d1a378e4205d69e9af6f31c0c3`

Source: [openai/codex](https://github.com/openai/codex), Apache-2.0.
Protocol documentation: [Codex app-server](https://learn.chatgpt.com/docs/app-server).

Capture with the pinned CLI (fish):

```fish
codex --version
codex app-server generate-json-schema --out /tmp/codex-schema
cp /tmp/codex-schema/codex_app_server_protocol.schemas.json codex-protocol/spec/schema.json
.venv/bin/python tools/gen/codex.py
```

When updating, review the CLI version, checksum, selected surface, generated diff,
and protocol tests together. The schema bundle includes legacy definitions; the
manifest selects v2 thread/turn methods plus the common initialization/approval
messages. It does not enable experimental API capabilities.

`surface.json` pairs requests with response definitions because the schema's
request union does not contain that mapping. Adding a method requires checking
the upstream RPC contract. Parameter references and event names come directly
from the upstream unions. Missing methods/references and unsupported shapes fail
generation. No OpenAPI document or HTTP operation is synthesized.

`tools/gen/codex.py` computes the selected reference closure, lowers JSON Schema
to the shared IR, and emits types, typed call descriptors, and event dispatch.
Serde external enums are modeled explicitly. Plain schema `true`/empty schemas
remain arbitrary JSON; optional nullable values retain absent/null/value states.
Unsigned 64-bit numbers use `UInt64Number` to keep their numeric wire format and
precision. Schema constraints such as minimum, regex patterns, and array lengths
are not a full validation layer; the server still validates requests.

Regeneration is offline. `scripts/generate.sh --check` verifies committed output;
the CLI is needed only to deliberately refresh the vendored schema.
