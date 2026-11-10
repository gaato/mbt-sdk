# Contracts

HTTP Backend, BodyStream, SendOptions, runtime ports and client attempts follow
[mttp's contract](https://github.com/gaato/mttp/blob/main/CONTRACT.md). This
repository consumes those interfaces; it does not implement HTTP engines.

## SDK calls

- Expected HTTP and deserialization failures are Result values containing
  mttp ResponseFailure, with the original response head and at most 1 MiB of
  diagnostic body. SDK validation failures are values too.
- TransportError, cancellation and unknown callback exceptions remain effects.
  A streaming callback runs once, after attempt release/observation, and is
  never retried. SSE bodies close on EOF, sentinels, failure and cancellation.
- Buffered replies default to mttp's 64 MiB limit. `max_body_bytes` overrides
  it. Streaming bounds each SSE event to 16 MiB, but tool-call accumulators
  still need caller limits on the total arguments assembled.
- OpenAI and Anthropic default to two retries, including POST, for 408, 409,
  429, 5xx and retryable network/timeouts, honoring x-should-retry. OpenAI
  stops on Retry-After above 120 seconds; Anthropic has no server-wait cap.
  Both use 600-second attempt budgets. Backends enforce those budgets;
  a total call budget requires Timer and includes admission, waits and callbacks.
- GitHub defaults to three conservative retries and its documented primary,
  secondary and GraphQL conditions. Writes/GraphQL/search are paced, and
  caller-supplied gates add serialization. Header windows are shared using
  x-ratelimit-resource. Query GraphQL failures can retry; mutations do not
  retry a transient response whose work may have been applied.

Pinned vendor sources and intentional differences are recorded under
[docs/behavior](docs/behavior). Public API types, defaults and examples are
in each module overview and generated interface.

## JSON-RPC framing

LineFramer receives arbitrary byte chunks and emits NDJSON records.

1. Splitting input at any byte, including CRLF and UTF-8 boundaries, does not
   change records or errors. Empty chunks are permitted.
2. feed returns only determined records. finish returns a final unterminated
   record, dropping a CR only when it precedes LF.
3. max_line bounds content bytes. The connection defaults to 64 MiB;
   LineFramer alone is unbounded unless configured.
4. An overflow after complete records returns those records first and raises
   on the next feed/finish. Otherwise it raises immediately.
5. After finish or a reported overflow, later calls are silent.

Conformance exercises these rules on fixed, generated and corrupted corpora.

## JSON-RPC connections and Codex sessions

Connection tasks and child processes belong to the caller's core/async
TaskGroup. Closing fails pending calls and closes the supplied writer once;
the reader stays caller-owned. Cancellation removes pending calls unchanged.
Call deadlines cover both send and receive. A partial cancelled write closes
the connection, so it cannot be reused for a corrupt record.

Notifications are handled in wire order. The default backlog is 32,768;
overflow fails the group. Inbound handlers and reply-only tasks are independently
bounded at 64. Excess requests receive -32001 without blocking response
dispatch behind a handler. Limits propagate through child/session constructors.

Codex initialization completes the initialize/initialized handshake before a
Client is returned and closes on handshake failure. Calls are never retried:
timeout/cancellation does not prove server work stopped. Session shutdown sends
EOF, then cancels and joins the process after its deadline.
