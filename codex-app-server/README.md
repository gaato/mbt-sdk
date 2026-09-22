# Codex app-server SDK

MoonBit client for the stable v2 surface of **codex-cli 0.155.1**. Experimental,
unpublished. Uses `gaato/jsonrpc-async`; protocol types come from the pinned JSON
Schema through `gaato/codex-protocol/gen`.

## Initial surface

- Initialization: `spawn` (native stdio) or `connect` (native/JS reader/writer).
  Both complete `initialize` and `initialized` before returning a `Client`.
- Typed calls: `thread_start`, `thread_resume`, `turn_start`, `turn_interrupt`.
- Typed events: error, thread started, turn started/completed, item
  started/completed, agent message delta. Other events use `Event::Unknown`,
  retaining the method name and optional JSON payload.
- Typed handlers: command approval, file approval, permission approval, and
  user input. Each returns `Result[Response, RpcError]`. Missing/unknown handlers
  return method-not-found; invalid known parameters return invalid-params.

The [surface manifest](../codex-protocol/spec/surface.json) is the exact scope.
Dynamic tool calls, auth refresh, MCP elicitation, and WebSocket transport are not
included in this initial SDK. `connect` expects newline-delimited JSON on its
reader/writer pair, not WebSocket frames.

## Usage

Import `gaato/codex-app-server` as `@codex`, `gaato/codex-protocol/gen` as
`@protocol`, `moonbitlang/async`, and `moonbitlang/async/aqueue`. Native example:

```moonbit
@async.with_task_group(group => {
  let completed : @aqueue.Queue[@protocol.TurnCompletedNotification] = @aqueue.Queue(kind=Unbounded)
  let session = @codex.spawn(
    group,
    @protocol.InitializeParams::new(
      client_info=@protocol.ClientInfo::new(name="my-integration", version="0.1"),
    ),
    on_event=event => {
      if event is ItemAgentMessageDelta(delta) { print(delta.delta) }
      if event is TurnCompleted(done) { completed.put(done) }
    },
    handlers=@codex.Handlers::new(command=_ => {
      // The host application decides; this example declines every command.
      Ok(@protocol.CommandExecutionRequestApprovalResponse::new(decision=Decline))
    }),
  )
  let started = session.client.call(
    @protocol.thread_start(@protocol.ThreadStartParams::new(ephemeral=true)),
  )
  let turn = session.client.call(@protocol.turn_start(
    @protocol.TurnStartParams::new(
      thread_id=started.thread.id,
      input=[Text(@protocol.UserInputText::new(
        type_="text", text="Hello", text_elements=[],
      ))],
    ),
  ))
  // turn/start only acknowledges the turn. Wait for its completion event.
  for ;; {
    let done = completed.get()
    if done.thread_id == started.thread.id && done.turn.id == turn.turn.id { break }
  }
  ignore(session.shutdown())
})
```

`src/client_test.mbt` contains an executable fake-server example including the
completion wait. `src/examples/initialize` runs the real CLI handshake without
starting a thread or making a model request:

```fish
set codex_smoke_home (mktemp -d /tmp/mbt-sdk-codex-home.XXXXXX)
moon run --target native codex-app-server/src/examples/initialize -- $codex_smoke_home
```

## Lifetime and errors

- Keep the task group alive for the connection/session lifetime. `connect`
  borrows the reader; its owner must close it after background tasks finish.
  `close_writer` must close output. Native `spawn` owns its pipes and process.
- Notifications run in wire order and requests dispatch concurrently. A handler
  can call back into the server. The inherited notification queue is unbounded;
  event consumers should hand off expensive work promptly.
- `Client::call` raises `RpcFailure` for remote errors, transport closure, or
  timeout. Bad response JSON raises `ClientError::InvalidResult` with the method
  name. Reinitialization raises `AlreadyInitialized` locally.
- Malformed known events and exceptions from application handlers propagate to
  the task group. Unknown events remain available as JSON.
- Call timeout/cancellation stops waiting; it does not cancel a server turn.
  Use `turn_interrupt` explicitly. Calls are never retried automatically.
- Handshake failure/cancellation closes output. `Session::shutdown` sends EOF,
  waits, then terminates a child that exceeds its grace period. Exiting the task
  group also bounds child lifetime.
- Optional nullable fields use `Presence` (absent/null/value). Constructors omit
  unset fields; set a field to `@sdkjson.Null` when explicit null is intended.
- The generated API projects JSON Schema types, not all validation constraints.
  It intentionally preserves open enums and unconstrained JSON. Empty-object
  response schemas such as turn/interrupt currently return `Json`.

Rebuild/check generated code with `scripts/generate.sh [--check]`; see the
[schema provenance](../codex-protocol/spec/README.md) for updating the CLI pin.
