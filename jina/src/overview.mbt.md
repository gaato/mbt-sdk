# gaato/jina

Jina API client for MoonBit, with typed requests and responses in
`gaato/jina/gen`. The caller supplies an HTTP backend or a configured
`gaato/mttp_core/client.Client`.

## Install

```sh
moon add gaato/jina
```

Import `gaato/jina`, `gaato/mttp_core/client` and the backend your application
uses. With an existing runtime client:

```mbt check
///|
pub async fn model(
  client : @client.Client,
  api_key : String,
  model_id~ : String,
) -> Unit {
  let jina = @jina.Jina::from_client(client, auth=Bearer(api_key))
  match jina.get_model(model_id~) {
    Ok(model) => println(model.name)
    Err(_) => println("Jina request failed")
  }
}
```

For an application using `gaato/mttp`, construct the backend and clock:

```mbt nocheck
///|
let jina = @jina.Jina::new(@mttp.backend(), @mttp.clock(), auth=Bearer(api_key))

///|
let models = jina.list_models()
```

## Limits and errors

The backend-plus-clock constructor uses conservative retries. POST is retried
only when it was not processed or is explicitly replay-safe. `from_client`
uses the supplied client's policy and shares its retry budget. Configure
`timeout_ms`, `total_timeout_ms` and a timer to bound calls. The default attempt
timeout is 60 seconds; no total timeout is set. Buffered responses default to
a 64 MiB limit.

Failures are `Http` (status, headers, bytes and an optional typed error body),
`Transport` (the original runtime error, including invalid Client defaults),
`Decode`, or `Validation` for invalid SDK input. Match with a
default arm because failures can gain variants. Unexpected callback errors
propagate. `Http` includes the operation identifier; typed error variants are
named after their schemas. Text operations return strings, binary operations
return consumed byte responses, and operations without a body return Unit.

The client supports wasm-gc, JavaScript and native targets; transport support
depends on your backend. See the
[specification source](https://api.jina.ai/openapi.json).
