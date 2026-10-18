# Resource bounds

What a long-running SDK client, JSON-RPC connection, or Codex session can
accumulate, and what keeps each structure from growing without limit. The
rule: **every structure that grows with input from the network, a peer
process, or the number of requests, buckets, connections, or pending calls is
listed here with its bound**. A new one — an `@aqueue.Queue(kind=Unbounded)`,
a map keyed by ids or names that arrive from outside, a buffer filled from a
socket — needs a row before it ships.

A bound is either a limit the code enforces, or the rate of the input times
how long an entry lives, where both are themselves bounded. Rows of the second
kind say what that product is. Rows marked with a PR number describe behaviour
that PR introduced (#40, #43, #44, #47, #48, #49), so they can be checked against it.

Scope: the hand-written modules `http` (with `http/sse`), `http-async`,
`sdk-runtime`, `jsonrpc`, `jsonrpc-async` and `codex-app-server`. The
generated SDKs (`openai`, `anthropic`, `github`) appear only where they buffer
responses or streams; they do so through `sdk-runtime`, the transport the
caller passes, and `@sse.each_event`. Test helpers (`http/mock`,
`http-async/mock`) record what a test feeds them and are not listed.

## Enforced limits

| Structure | Bound | On overflow |
|---|---|---|
| One SSE event (`http/src/sse/parser.mbt`, `SseParser::feed`) (#44, #47) | `max_event_bytes`, default 16 MiB: the raw bytes of everything the parser holds for the event, terminators excluded: its `data` lines, the `event` and `id` lines in effect (a persisting `id` counts against every event it goes out with), and the line being read. Held as UTF-16 strings, near-limit ASCII takes roughly twice that in memory. `each_event` uses the default, so the OpenAI and Anthropic streams (`openai/src/operations.mbt`, `anthropic/src/operations.mbt`) are bounded by it | The parser ends and raises `HttpError::Protocol`. Events completed earlier in the same chunk are returned first and the error comes on the next `feed` or `finish`; `each_event` calls `feed(b"")` after every chunk, so it raises before reading further. |
| One JSON-RPC line (`jsonrpc/src/framer.mbt`, `LineFramer::feed`, `LineFramer::finish`; `jsonrpc-async/src/connection.mbt`, `Connection::start`) (#40, #49) | `max_line` content bytes; the CR of a CRLF terminator is exempt. `Connection::start` defaults it to 64 MiB (`default_max_line`); `spawn_child` and codex-app-server's `spawn` and `connect` pass theirs through, so a Codex session has the same default. `LineFramer::new` on its own has no default: the transport sets it | `LineTooLong`, and the framer ends. Lines completed earlier in the same chunk are returned first and the error comes on the next `feed` or `finish`; `finish` also checks an unterminated last line. The read loop calls `feed(b"")` after each chunk, turns it into `RpcFailure::Transport("JSON-RPC line exceeds N bytes")`, fails every pending call with that failure, and raises it into the group |
| JSON-RPC notification backlog (`jsonrpc-async/src/connection.mbt`, `Connection::start`, `notifications : @aqueue.Queue(kind=Blocking(max_notifications))`; `dispatch.mbt`, `Connection::dispatch`, `try_put`) (#49) | `max_notifications` notifications received but not yet passed to the sequential `on_notification` handler, default 32,768 (Codex emits up to 10,000 output deltas per command; its TUI buffers 32,768 events per thread); the one the handler holds is not counted. `spawn_child` and the Codex `spawn` and `connect` pass it through | The connection fails: `RpcFailure::Transport("JSON-RPC notification backlog exceeds N notifications")` to every pending call and the group. The read loop never waits for the handler instead, because a handler awaiting a call's response needs the read loop to deliver it |
| Inbound request handlers and reply-only tasks (`jsonrpc-async/src/dispatch.mbt`, `Connection::dispatch`, `Connection::reply_later`; `connection.mbt`, the `handlers` and `replies` semaphores) (#49) | `max_inbound`, default 64, counted separately for request handlers running at once and for reply-only tasks (overload refusals, `id: null` errors for malformed lines) waiting to write. `spawn_child` and the Codex `spawn` and `connect` pass it through | A request past the handler limit is answered with `-32001` "Server overloaded; retry later." (Codex's own saturation error) without calling `on_request`, so a handler's outbound call never waits behind a blocked read loop. Past the reply limit the read loop waits for a reply task to finish, which depends only on the peer reading, not on any handler. A peer that writes without reading stalls the connection at `max_inbound` handlers, `max_inbound` replies and one line, until the group ends |
| Buffered response body (`http-async/src/transport.mbt`, `read_body`, `read_bounded`) | `max_body_bytes`, when given: decoded bytes, after the automatic gzip decoding. There is no default, see "Left to the caller" | The chunk that would cross it raises `Protocol` without being kept; `AsyncTransport::send`'s `errdefer` closes the connection |
| Error body kept in an `SdkError` (`sdk-runtime/src/error.mbt`, `classify`; `client.mbt`, `read_error_body`) (#48) | 1 MiB, buffered and streaming alike | Buffered: `Status` and `RateLimited` keep a copy of the first 1 MiB, and the rest goes when the response is freed. Streaming: the rest is not read, and the stream is closed undrained, so its connection is not reused |
| Exchange time (`http-async/src/transport.mbt`, `bounded`, used by `AsyncTransport::send`, `send_stream`, `ClientStream::read_some`) | `timeout_ms`, default 30 s: the whole buffered exchange, a streaming exchange up to its head, and each stream read | `HttpError::Timeout`; the connection is closed. This is what bounds the response head and an unlimited buffered body, see the known gaps |
| Replays of a request on a stale connection (`http-async/src/transport.mbt`, `AsyncTransport::open_request`) | One, and only for a replayable request (`pool.mbt`, `replayable`) on a reused connection | The failure is raised |
| Retries of one call (`sdk-runtime/src/retry.mbt`, `RetryPolicy::next_delay_ms`; `sdk-runtime/src/backoff.mbt`, `Backoff::delay_ms`) | `max_retries`, default 2; backoff capped at `max_ms` (30 s); a server delay over `max_retry_after_ms` (60 s) is not waited for. A custom `RetryDecider` sets its own bound | The last error is raised |
| `Paginator::collect` result (`sdk-runtime/src/paginator.mbt`) | `max` items, chosen by the caller; the unused rest of the last page is kept in `pending`, at most one page | Collection stops |

## Bounded by rate and lifetime

| Structure | Grows with | Bound |
|---|---|---|
| Parked keep-alive connections (`http-async/src/pool.mbt`, `IdlePool::put`, `IdlePool::sweep`) (#43) | Distinct origins one transport talks to, times `max_idle_per_origin` (default 4); there is no cap across origins | Eviction is lazy: every checkout and checkin closes the connections parked longer than `idle_max_ms` (default 10 s) across all origins and forgets emptied origins, but no timer runs, so after the last request they stay parked until the next request or `close()`. A connection over the per-origin cap is closed instead of parked. #43 parks a connection unless `Connection` carries `close` as a whole token |
| Rate-limit bucket gates (`sdk-runtime/src/rate_limit.mbt`, `WindowLimiter::join_gate`, `leave_gate`) | Requests holding or waiting on a bucket's gate | Requests in flight: an entry leaves when both its holder and waiter counts reach zero, including after a cancelled `acquire` (`errdefer`) |
| Rate-limit states (`sdk-runtime/src/rate_limit.mbt`, `WindowLimiter::sweep_states`, `acquire`) | Distinct bucket names with a recorded window | Eviction is lazy: a `release` sweeps expired states when the map has doubled since the last sweep (floor 64) or a minute has passed since it, and `acquire` drops its own bucket's expired state. No timer runs, so when traffic stops, states stay until the next `release`, however long ago they expired. Bucket names come from the caller. Among the facades only GitHub installs a `WindowLimiter` by default (`github/src/client.mbt`, `default_limiter`), over three buckets (`core`, `search`, `graphql`; `github/src/call.mbt`, `rate_limit_bucket`); OpenAI and Anthropic use `NoLimiter` and name a fixed bucket per operation family. A state lives until its reset, as far ahead as the server says: a `Retry-After` override is capped at `Int32` milliseconds, but a reset parsed from headers (`rate_limit_headers`, GitHub's default, reads `x-ratelimit-reset` through `decimal_seconds_ms`) is an absolute `Int64` instant and can lie arbitrarily far ahead |
| Account-wide window (`sdk-runtime/src/rate_window.mbt`, `global_step`) | Admissions | Constant: one window start, one count, one block deadline |
| Gate waiters (`http-async/src/gate.mbt`, `SemaphoreGate`) | Tasks waiting for a permit | The caller's concurrency |
| Response streams (`http-async/src/transport.mbt`, `ClientStream`) | Body bytes | The transport keeps nothing between reads; the reader decides what to keep. A stream may last indefinitely while each read arrives within `timeout_ms` |
| `Paginator::each` and `next_page` (`sdk-runtime/src/paginator.mbt`) | Pages | One page at a time. A server that always names a next page keeps the walk fetching, in constant memory; the callback stops it by raising |
| Pending JSON-RPC calls (`jsonrpc-async/src/connection.mbt`, `Connection::call`, `fail_pending`; `dispatch.mbt`, `Connection::dispatch`) | Calls in flight | One entry per call, removed by its response or failure, by the call's `defer` on return, timeout, or cancellation, and all at once when the connection closes or reading ends. Each reply queue receives at most one value, since the entry is removed before the put. A call without `timeout_ms` to a peer that never answers lasts until the connection ends; the Codex handshake has a 10 s deadline (`codex-app-server/src/client.mbt`, `initialize_connection`) |
| Codex child process (`codex-app-server/src/child.mbt`, `spawn`; `jsonrpc-async/src/child.mbt`, `spawn_child`, `Child::shutdown`) | stdout and stderr output | stdout is read continuously by the connection's read loop; stderr is inherited, never buffered here. The child and its pipes end with the caller's task group, and `shutdown` cancels the child after its timeout |

## Left to the caller

Growth that follows what the caller asks for, not what the network sends.

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| Buffered response body size (`http-async/src/transport.mbt`, `AsyncTransport::new`, `max_body_bytes?`) (#48) | Response size, unless the caller sets `max_body_bytes` | The facades (`OpenAI::new`, `Anthropic::new`, `GitHub::new`) use the transport they are given, so its owner sets the limit. Every README's setup and the live tests use `max_body_bytes=64 * 1024 * 1024`; the GitHub README sends file downloads to `send_stream` on the redirect target, or to a client with a larger limit. Unset, the bound is `timeout_ms` (30 s) times bandwidth. `Decode` keeps the successful body under that same limit |
| Streamed tool-call reassembly (`openai/src/types.mbt`, `ToolCallAccumulator::feed`; `anthropic/src/tools.mbt`, `ToolUseAccumulator::feed`) | The tool-call arguments of one stream, as the caller feeds the deltas | Arguments must be whole to be parsed. Each delta is within one SSE event's bound, but nothing caps their total: a request without a token limit, or an endpoint that keeps streaming while each read meets its timeout, grows the accumulator without end. The caller feeds it, so the caller caps it, by total events or accumulated bytes; set a token limit on the request as well |
| `Paginator::collect` | `max` | The caller states how many items it wants |
| A custom `RetryDecider` (`sdk-runtime/src/retry.mbt`) | Attempts | The decider is the policy |

## Known gaps

Growth the library does not bound yet, with what limits it in practice and how
it could be fixed.

| Structure | Grows with | What limits it | Suggested fix |
|---|---|---|---|
| Response heads, chunk-size lines, and chunked trailers (moonbitlang/async 0.22.5 `src/http/parser.mbt`, `Reader::read_response`, `read_headers`, the `Chunked(0)` branch of `_direct_read`, all `read_until("\r\n")` with no limit; header values are joined into one `Map` and every `Set-Cookie` kept) | Header and line size from the server | `timeout_ms` times bandwidth: the whole exchange for `send`, the head for `send_stream`, one read for a trailer | A head and line limit in moonbitlang/async; nothing above `@ahttp.Client` can see the head before it is parsed |
