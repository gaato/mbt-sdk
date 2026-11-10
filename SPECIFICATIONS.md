# Specifications

HTTP syntax, URL, cookies, SSE, multipart, content codings, redirects and client
attempt semantics are implemented by [mttp](https://github.com/gaato/mttp).
Its [contract](https://github.com/gaato/mttp/blob/main/CONTRACT.md) and ledgers
own the implementation limits and deviations. This repository retains external
URL/cookie/SSE conformance corpora as consumer checks, alongside JSON-RPC tests.

| Document | Implementation | Scope |
|---|---|---|
| JSON-RPC 2.0 | jsonrpc/src/message.mbt, types.mbt | Requests, notifications, responses, standard error codes; strict and bare envelopes; batches refused |
| NDJSON convention | jsonrpc/src/framer.mbt | LF records, optional preceding CR; final unterminated record; configurable byte limit |
| JSON Schema draft-07 | tools/gen/codex.py | Pinned Codex app-server schema and explicit request/response manifest |
| OpenAPI 3.0 and 3.1 | tools/gen | Nullable/type-array dialects, selected or all operations, refusal of unsupported shapes |
| OpenAPI Overlay 1.0 | tools/apply_overlay.py | update/remove actions, JSONPath selectors |
| RFC 9535 JSONPath | jsonpath-rfc9535 dependency | Overlay targets |
| WHATWG Encoding | jsonrpc/src/utf8.mbt | UTF-8 encoding, lone surrogate replaced with U+FFFD |

The generator's census records every intentional Json escape hatch in
[docs/census.md](docs/census.md). Vendor retry, timeout and pacing conventions
are pinned in [OpenAI](docs/behavior/openai.md),
[Anthropic](docs/behavior/anthropic.md) and [GitHub](docs/behavior/github.md).
These sources are preserved through the HTTP-stack migration; no API specs
were refreshed for that migration.

## Conventions

The bare JSON-RPC envelope is used only for protocols such as Codex app-server
that omit jsonrpc. Request identifiers preserve strings and integral numbers.
Malformed UTF-8 and malformed JSON are protocol failures; framing never
normalizes the content of a line.

Generated models ignore unknown object properties and retain unknown open-enum
or explicitly extensible union cases. Request Presence fields distinguish
omission, null and a value using mttp/jsonkit. Int64 helpers preserve integral
wire values without a floating-point round trip.

## HTTP migration observations

The new backend reports truncated framing as TransportError(Protocol, Body),
size overflow as TooLarge and refused downgrade as RedirectRefused. It preserves
header octets as Latin-1 and retains nameless Set-Cookie fields, unlike the
previous adapter. Recorded replay expectations describe those changes.
JS fetch remains constrained by host header visibility and host decoding;
see the upstream contract for target-specific exceptions.
