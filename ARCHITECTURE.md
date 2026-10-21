# Architecture

This repository holds the pieces for writing API SDKs in MoonBit and keeping
them alive: a sans-IO HTTP vocabulary, an API-agnostic client runtime, SDKs
generated from the vendors' own API descriptions, and the adapters that run
them on an async runtime. The two things that rot an unofficial SDK, upstream
API changes and language changes, are each absorbed in one place: the
generator and its overlays for the first, the pinned toolchain and the daily
canary for the second.

## Layers

```
applications    your code: picks a transport, a clock and an SDK
──────────────┼─────────────────────────────────────────────────────────────
adapters        gaato/http-async    gaato/jsonrpc-async    gaato/codex-app-server
                  the only modules that import moonbitlang/async
──────────────┼─────────────────────────────────────────────────────────────
APIs            gaato/openai  gaato/anthropic  gaato/github  │  gaato/codex-protocol
                  generated types and operations under a hand-written facade
──────────────┼─────────────────────────────────────────────────────────────
runtime         gaato/sdk-runtime: errors, retries, timeouts, rate limits,
                  pagination, streaming, for any HTTP API
──────────────┼─────────────────────────────────────────────────────────────
vocabulary      gaato/http                     │  gaato/jsonrpc
                  requests, responses, the       │    messages, envelopes,
                  Transport and BodyStream       │    line framing
                  traits, SSE, cookies, retries  │
```

A module depends only on the layers below it. Everything from the
vocabulary up to the APIs is sans-IO and runs on every backend (wasm-gc,
wasm, js, native); only the adapters, and the unpublished `runtime-tests`
that drive them, are limited to the backends moonbitlang/async supports.

**Vocabulary.** `gaato/http` defines what every layer above talks in:
`Request`, `Response`, `Headers`, the `Transport` and `BodyStream` traits,
`HttpError` with the `Phase` a failure happened in, and the parts of HTTP an
SDK needs but no transport provides: `Retry-After` and `Link`, an SSE
parser, a cookie jar, a multipart writer, redirects as a middleware step,
and retry decisions as data (`gaato/http/retry`). `gaato/jsonrpc` does the
same for JSON-RPC 2.0. Neither has dependencies. What a transport and a
parser must guarantee is written down in [CONTRACT.md](CONTRACT.md), and the
specifications they follow in [SPECIFICATIONS.md](SPECIFICATIONS.md).

**Runtime.** `gaato/sdk-runtime` is the client every SDK shares: it sends
through the caller's `Transport`, classifies failures into `SdkError`,
retries by a `RetryPolicy` built on `gaato/http/retry`, bounds calls with
`Timeouts`, paces with `WindowLimiter`, and pages with `Paginator`. It knows
nothing about any particular API. Time comes in through the `Clock` and
`Timer` traits, so its retry and rate-limit logic is tested with a fake
clock.

**APIs.** Each API module is generated from the vendor's own description,
vendored under `<module>/spec/`, by `tools/gen`:

```
spec → overlays/fix.yaml → overlays/moonbit.yaml → normalise → IR → <module>/src/gen/*.mbt
        (upstream errors)    (MoonBit decisions)      tools/gen (Python)
```

The generated code is committed, so users need no Python. The generator is
written in Python on purpose (`docs/design-m4.md`): a generator written in
MoonBit would itself break when the language changes, which is the event it
exists to absorb. It refuses shapes it cannot represent, with a JSON pointer
to the overlay that would decide them, instead of degrading to raw `Json`;
`docs/census.md` lists what stays `Json` and why. A hand-written facade on
top sends, retries and streams through `sdk-runtime`, and follows the
vendor's official SDK in what it retries and how long it waits
(`docs/new-sdk.md`, `docs/behavior/`). `gaato/codex-protocol` is generated
the same way from a pinned JSON Schema.

**Adapters.** In MoonBit an import applies to a whole module, test imports
included, so a module that imported moonbitlang/async anywhere would carry
it into every user's dependency graph. The async code therefore lives in
modules of its own: `gaato/http-async` implements `Transport` (a keep-alive
pool, timeouts by phase, proxies, content decoding) and `Clock`;
`gaato/jsonrpc-async` runs a bidirectional JSON-RPC connection over any
reader and writer pair or a child process; `gaato/codex-app-server` builds a
Codex session on it. The same rule is why `runtime-tests` exists: it is the
unpublished module where the async behaviour of the layers below is run.

## Testing

- **Gates** (`scripts/gates.sh`): every module checked with `--deny-warn` on
  each backend it supports, the tests on wasm-gc, js and native, the
  generator's unit tests, generated code compared with a fresh generation,
  formatting, the public interfaces (`pkg.generated.mbti`), and the
  generator's census of each vendored spec. CI runs them on a pinned
  toolchain image.
- **Conformance** (`conformance/`, unpublished): the sans-IO parsers held
  to the rules of `CONTRACT.md` by one harness, from outside their modules
  as a consumer would see them. Every input runs whole, cut in two at every
  place, a byte at a time, around every CR and multibyte character and at
  random, and must give the same results and error; every prefix gives out
  only what it determines; a finished or failed parser stays silent; and
  seeded corruptions of each corpus hold to the same rules, the outcomes
  counted in a snapshot.
- **Ledgers.** `RESOURCE_BOUNDS.md` lists every structure that grows with
  input from the network, a peer or the number of requests, with its bound
  and, for each enforced limit, the tests that drive it to the limit;
  `scripts/bounds_check.sh` checks that those tests exist.
  `TEST_COVERAGE.md` explains every line of the hand-written modules that
  tests do not reach; `scripts/coverage_report.sh` fails on any other.
- **Specifications.** `SPECIFICATIONS.md` records the documents followed,
  the errata that touch implemented sections, the conventions followed
  where no document applies, and known deviations.
- **Third-party test data.** Published test suites are run as data, pinned
  to a commit, with their licenses in the module's NOTICE: web-platform-tests'
  URL and event-stream tests, the http-state cookie tests and go.lsp.dev's
  JSON-RPC vectors in `conformance/`, and the NO_PROXY tables of Go and curl
  in `http-async`. `scripts/gen_vectors.mbtx` rewrites the larger ones as
  MoonBit test files when their pins move. Where this code deliberately
  differs from a suite, the rows it skips are named by category and
  counted, and the difference is listed in `SPECIFICATIONS.md`.
- **Recorded responses.** badhttp.dev's content-coding, cookie, event
  stream and cross-host redirect responses (CC0), recorded byte for byte by
  `scripts/capture_badhttp.mbtx`, are played back by a loopback server in
  `runtime-tests/src/badhttp_replay`, so the transport, decoders, jar,
  parser and redirects meet them in every gates run without the network.
- **Live and scheduled.** `scripts/live.sh` runs the SDKs against the real
  APIs and local compatible servers; `scripts/conformance.sh` runs the
  transport, SSE parser and runtime against https://badhttp.dev. The
  `canary` workflow runs the gates daily on the latest toolchain, so red
  there and green in CI means the language moved; `spec-watch` re-vendors
  the specs daily and opens a pull request when they change.

## Where things are not

- **HTTP/1.1 framing, TLS and sockets** are moonbitlang/async's.
  `gaato/http-async` builds requests and reads responses through its client.
  On native it speaks HTTP/1.1 only; on JS, fetch chooses the protocol.
- **Compression formats** (gzip, deflate, Brotli, Zstandard) are decoder
  modules of their own, from codecs.mbt and moonbit-community/flate;
  `gaato/http-async` only reads `Content-Encoding` and chains them.
- **GraphQL** is reached through the GitHub client as a passthrough over
  `Json`: a GraphQL response's shape belongs to the query the caller wrote,
  so there is no operation-to-type table to generate.
- **Browser behaviour** that has no meaning for an API client is left out:
  cookies are not refused for cross-site requests, `HttpOnly` cookies are
  sent, and there is no SSE reconnection.
