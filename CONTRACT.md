# Contracts

What code on either side of the `gaato/http` traits may rely on, and what
the sans-IO parsers guarantee. A transport, a test double or a wrapper that
keeps these rules can be used with every SDK here; a consumer written
against them needs nothing more. The traits themselves are in
`http/src/transport.mbt`.

## Transport and BodyStream

```moonbit
pub(open) trait BodyStream {
  async fn read_some(Self) -> Bytes? raise HttpError
  fn close(Self) -> Unit
}

pub(open) trait Transport {
  async fn send(Self, Request) -> Response raise HttpError
  async fn send_stream(Self, Request) -> (ResponseHead, &BodyStream) raise HttpError
}
```

### Rules for a transport

1. **Statuses are responses.** Every response the server sends back, 4xx and
   5xx included, is returned, never raised. The one exception is a proxy
   refusing a tunnel the transport opened itself (`CONNECT` for an `https`
   origin), raised as `HttpError::Proxy`, since no response came from the
   origin. Deciding what a status means is the caller's (`sdk-runtime`'s
   `classify`).
2. **Redirects are responses.** A 3xx is returned as it is; following it is
   the `redirects` middleware step or `follow_redirects_stream`, which
   decide what to strip and resend.
3. **Informational responses are not surfaced**, except `101`, which is
   final and ends the connection's reuse.
4. **Failures say how far the exchange got.** `HttpError::Connect` and a
   `Timeout` in `Pool` or `Dial` mean no byte of the request was sent
   (`HttpError::is_unsent`), so a caller may resend even a request that is
   not idempotent. Any other failure may have reached the server. `Network`
   and `Timeout` carry the `Phase` they happened in, or `Unknown` when the
   transport cannot tell. A malformed response, or one past a limit the
   transport enforces, is `Protocol`.
5. **Cancellation is not an error of the transport.** When the task running
   an exchange is cancelled, the cancellation propagates as the runtime's
   signal; it is never turned into an `HttpError`, and the transport's
   resources are released on the way out.
6. **Header names are case-insensitive**, as `Headers` stores and looks them
   up in lower case. Repeated fields keep their order.
7. **`send` reads the whole body.** A transport that bounds it raises
   `Protocol` at the chunk that would cross the bound and keeps nothing past
   it. Content codings it undoes are removed from `Content-Encoding`, and
   `Content-Length` with them, in both `send` and `send_stream`.
8. **A request body is read at most once per attempt.** A transport resends
   a request on its own only when nothing reached the server and the body
   can be replayed (`Body::is_replayable`); a stream body taken by an
   exchange is closed by the transport when the exchange ends. A stream body
   the transport never took stays its creator's to close.

### Rules for a body stream

9. **`None` is the end, and stays the end.** After `read_some` returns
   `None`, every later call returns `None`. A chunk is never empty; a
   consumer that meets one anyway treats it as no data, not as the end.
   Chunk sizes are the stream's choice; consumers must not rely on a bound.
10. **A failed stream is done.** After `read_some` raises, the caller does
    not read again, only closes. An implementation may return `None` to a
    read after an error, which is why a caller must not take that `None`
    for a clean end.
11. **`close` is idempotent and always allowed**: before the end, at it,
    after it and after an error. Closing before the end abandons the rest of
    the body, so a pooled connection is not reused.

### Rules for a consumer

12. **Every stream returned by `send_stream` is closed**, on every path:
    after reading it to the end, after stopping early, and when the code
    reading it raises or is cancelled (`defer stream.close()`). This holds
    for bodiless responses too (`HEAD`, `204`, `304`), whose first read
    returns `None`.
13. **No status, phase or chunk size is assumed** beyond what these rules
    say.

### Implementations checked against the rules

| Implementation | Holds | Notes |
|---|---|---|
| `AsyncTransport`, native and moonrun Wasm (`http-async`) | all | Phases are exact; chunks are at most 64 KiB; reaching `None` returns a keep-alive connection to the pool even before `close`. A read after an error returns `None` (rule 10). |
| `AsyncTransport`, JS (`http-async`) | all but 2, 6, 7 | fetch follows redirects (its default), so rule 2 does not hold, and fetch combines repeated header fields and hides `Set-Cookie`. Failures before the head are `Network(Unknown)` or `Timeout(Unknown)`, never `Connect`, so rule 4 holds by saying less. fetch decodes content codings itself and the head keeps the original `Content-Encoding` and `Content-Length`, against rule 7. These come from moonbitlang/async's fetch client, which calls fetch without a `redirect` option and copies the response headers into a map. |
| `DeadlineTransport` (`http-async`) | all | Raises `Timeout(phase=Unknown)` when its deadline ends an exchange; passes the inner stream through. |
| `FakeTransport` and its stream (`http/mock`) | all | Returns what the test scripted, empty chunks included, so tests can reach rule 9's "never empty" from the consumer side. |
| `TakenStream` (`http/src/body.mbt`) | all | Holds a request stream to its declared length; `close` forwards to the source, so idempotence is the source's. |
| `MultipartStream` (`http/multipart`) | all but 10 | After a part's stream raises, a further read reads that part again instead of staying done. Its consumer, the transport, never reads again (rule 10's caller side), so nothing observes it. |
| `sdk-runtime` `Client` (consumer) | 12, 13 | Closes every non-2xx stream after reading its error body, and any stream it opened if a limiter or timer step fails. `send_stream` does not run middleware, so a `redirects` step does not apply to streams; use `follow_redirects_stream`. |
| `@sse.each_event`, `follow_redirects_stream` (consumers) | 12, 13 | `defer`/`errdefer` close on every path, cancellation included. |

## Incremental parsers

`SseParser` (`http/sse`) and `LineFramer` (`jsonrpc`) take a byte stream in
chunks and give out what it contains: SSE events, NDJSON lines.

```moonbit
fn SseParser::feed(Self, Bytes) -> Array[SseEvent] raise HttpError
fn SseParser::finish(Self) -> Array[SseEvent] raise HttpError
fn LineFramer::feed(Self, Bytes) -> Array[Bytes] raise DecodeError
fn LineFramer::finish(Self) -> Bytes? raise DecodeError
```

1. **Splitting does not matter.** The results, and the error if any, do not
   depend on how the input is cut into chunks, down to one byte at a time,
   empty chunks included.
2. **Only what the input determines.** `feed` gives out a result as soon as
   the bytes so far complete it, and never one that later bytes could
   change; what `feed` gives out for a prefix of a stream is a prefix of
   what the whole stream gives. `finish` says the input has ended: the SSE
   parser drops an event that no blank line ended, the line framer gives out
   a last line that no newline ended.
3. **Memory is bounded by a limit the caller sets** (`max_event_bytes`, 16
   MiB by default; `max_line`, unbounded unless given), counted as
   `RESOURCE_BOUNDS.md` states.
4. **An overflow is raised once, after the results before it.** When a
   chunk completes results and then crosses the limit, `feed` returns those
   results and the next call, `feed` (an empty chunk is enough) or
   `finish`, raises. Otherwise the call that crosses the limit raises.
5. **A finished parser is silent.** After `finish`, or after the overflow
   has been raised, every `feed` and `finish` returns nothing and raises
   nothing. This differs from codecs.mbt's rule that errors stick: a parser
   here reports a failure once and then behaves as an ended stream, which
   is what its callers (`each_event`, the JSON-RPC connection) need to stop
   cleanly.
