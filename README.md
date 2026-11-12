# mbt-sdk

API SDKs and a Codex app-server client for [MoonBit](https://www.moonbitlang.com/).
Pinned upstream API descriptions generate the public vocabulary; small facades
add vendor-specific retries, streaming, pagination and error interpretation.

| Module | Purpose | Dependencies |
|---|---|---|
| [gaato/openai](openai/README.md) | Models, embeddings, Responses and Chat Completions | mttp_core |
| [gaato/anthropic](anthropic/README.md) | Messages, token counting, Models, tools and streaming | mttp_core |
| [gaato/github](github/README.md) | Generated REST API, pagination and GraphQL | mttp_core |
| gaato/jsonrpc | Portable JSON-RPC messages and NDJSON framing | core |
| gaato/jsonrpc-async | Bidirectional connections and native child processes | jsonrpc, core/async |
| gaato/codex-protocol | Generated typed Codex calls/events | mttp_core/jsonkit |
| [gaato/codex-app-server](codex-app-server/README.md) | Initialized sessions, typed events and handlers | protocol, jsonrpc-async, core/async |

The three HTTP SDKs are published on mooncakes. JSON-RPC and Codex modules
remain unpublished. HTTP infrastructure lives in [mttp](https://github.com/gaato/mttp):
gaato/mttp_core supplies the vocabulary, Backend and the client policy, and
gaato/mttp supplies the I/O an app adds. SDK modules do not import a
runtime.

The caller supplies a Backend and clock. Wrap AsyncBackend in Decompress when
content decoding is wanted, and supply ClockTimer for a total call deadline.
SDK failures are Result values; TransportError and callback exceptions remain
effects. Buffered bodies default to 64 MiB, SSE events to 16 MiB. Each module
overview has checked usage examples and its retry/timeout behavior.

## Development

- `scripts/generate.sh` regenerates from pinned specs and overlays;
  `scripts/generate.sh --check` verifies committed output.
- `scripts/gates.sh` checks supported targets, tests, interfaces, formatting,
  generation, spec census, resource bounds and documentation.
- `moon run scripts/coverage_report.mbtx` verifies the coverage ledger.
- `scripts/live.sh` and `scripts/compat-servers.sh` are opt-in and require
  credentials or servers. They are excluded from ordinary gates.

See [ARCHITECTURE.md](ARCHITECTURE.md), [CONTRACT.md](CONTRACT.md),
[SPECIFICATIONS.md](SPECIFICATIONS.md), [resource bounds](RESOURCE_BOUNDS.md),
[coverage](TEST_COVERAGE.md), [adding an SDK](docs/new-sdk.md) and
[releasing](docs/release.md).

Apache-2.0.
