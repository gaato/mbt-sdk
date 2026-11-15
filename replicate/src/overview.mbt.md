# gaato/replicate

Replicate API client for MoonBit, with typed requests and responses in
`gaato/replicate/gen`. The caller supplies a backend or an existing
`gaato/mttp_core/client.Client`.

## Install

```sh
moon add gaato/replicate
```

Import `gaato/replicate` and `gaato/mttp_core/client`. With a configured runtime
client, read the authenticated account:

```mbt check
///|
pub async fn account(client : @client.Client, api_key : String) -> Unit {
  let replicate = @replicate.Replicate::from_client(
    client,
    auth=Bearer(api_key),
  )
  match replicate.account_get() {
    Ok(account) => println(account.username)
    Err(_) => println("Replicate request failed")
  }
}
```

An application using `gaato/mttp` can supply its backend and clock directly:

```mbt nocheck
///|
let replicate = @replicate.Replicate::new(
  @mttp.backend(),
  @mttp.clock(),
  auth=Bearer(api_key),
)

///|
let account = replicate.account_get()
```

List operations with a `next` URL have `_pages` methods with the same labelled
parameters as the operation. Pages contain typed items; a null or absent `next`
finishes iteration. For example:

```mbt check
///|
pub async fn versions(
  client : @client.Client,
  api_key : String,
  owner~ : String,
  name~ : String,
) -> Unit {
  let replicate = @replicate.Replicate::from_client(
    client,
    auth=Bearer(api_key),
  )
  let pages = replicate.models_versions_list_pages(
    model_owner=owner,
    model_name=name,
  )
  match pages.next_page() {
    Ok(Some(versions)) => println(versions.length())
    _ => ()
  }
}
```

A failed page can be retried without advancing. Offset pagination is not
supported.

## Limits and errors

The backend-plus-clock constructor allows five retries: GET, HEAD, PUT, DELETE
and OPTIONS on 429, 500, 502, 503 and 504; POST only on 429, when the request
was not processed. Transport failures are not retried. Retry-After is honoured
up to 60 seconds; larger delays fall back to exponential backoff with jitter.
`from_client` uses the supplied client's policy and shares its retry budget.
The default per-attempt timeout is 70 seconds to accommodate `Prefer: wait`;
no total timeout is set. Override `timeout_ms`, and supply `total_timeout_ms`
and a timer to bound the whole call.
Buffered responses have a default limit of 64 MiB. Binary response operations
return consumed response bytes. Raw uploads take bytes and a content type.

Text responses return strings; operations without a response body return Unit.
Failures distinguish `Http` (operation, status, headers, bytes and optional error JSON),
`Transport` (the original transport error with its phase), and `Decode`.
Match with a default arm. Unexpected callback errors propagate.
The client supports wasm-gc, JavaScript and native targets, subject to the
chosen backend. See the
[specification source](https://api.replicate.com/openapi.json).
