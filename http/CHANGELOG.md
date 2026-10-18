# Changelog

All notable changes to `gaato/http` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.2] - 2026-10-16

### Changed

- **`percent_encode` and `percent_encode_path` are built on
  `moonbitlang/core`'s `encoding/percent`.** The output is unchanged; new
  tests pin slashes, sub-delimiters and astral characters.

## [0.1.1] - 2026-10-15

### Added

- **URL helpers shared by the generated SDKs:** `percent_encode` (keeps only
  RFC 3986 unreserved bytes), `percent_encode_path` (also keeps `/`) and
  `append_query`. Before, every generated module carried its own copy.
- **Package `gaato/http/sync` with a `Gate` trait** (`acquire` / `release`),
  so a runtime can serialize work without depending on an async runtime;
  `gaato/http-async` provides `SemaphoreGate`.
- **`FakeTransport::expect_error`** scripts a transport failure for a request.

## [0.1.0] - 2026-09-22

### Added

- Initial release: `Request`, `Response`, `Headers`, the `Transport` and
  `BodyStream` traits and middleware (`send_with`); a `Clock` trait
  (`gaato/http/clock`); an incremental SSE parser (`gaato/http/sse`); and a
  scripted `FakeTransport` and `FakeClock` for tests (`gaato/http/mock`). No
  dependencies; runs on wasm-gc, wasm, js and native.
