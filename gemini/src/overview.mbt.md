# gaato/gemini

A client for Google's native Gemini API in MoonBit: text and multimodal
generation, streaming, embeddings, token counting, file uploads and context
caching, with typed request and response models in `gaato/gemini/gen`.

For plain chat, [gaato/openai](https://mooncakes.io/docs/gaato/openai) also
works with Gemini's
[OpenAI-compatible endpoint](https://ai.google.dev/gemini-api/docs/openai).
Use this module when you need what only the native API has: uploaded files,
cached content, safety settings, thought signatures, grounding metadata and
typed media parts.

Unofficial, and not affiliated with Google. A minor release can change the
API; the
[changelog](https://github.com/gaato/moonbit-sdks/blob/main/gemini/CHANGELOG.md)
lists each change.

## Install

```sh
moon add gaato/gemini
moon add gaato/mttp
```

Import `gaato/gemini` and `gaato/gemini/gen`. `gaato/mttp` supplies the network
and the clock. Also add `gaato/mttp_core` if you pass an existing
`gaato/mttp_core/client.Client` to `Gemini::from_client`, or if you write a
library that takes the backend from its caller.

## Generate text

```mbt check
///|
fn print_text(reply : @gen.GenerateContentResponse) -> Unit {
  for candidate in reply.candidates.unwrap_or([]) {
    if candidate.content is Some(content) {
      for part in content.parts.unwrap_or([]) {
        if part is Text(piece) {
          println(piece.text)
        }
      }
    }
  }
}

///|
pub async fn generate(
  gemini : @gemini.Gemini,
  model_id : String,
  prompt : String,
) -> Result[Unit, @gemini.Failure] {
  let request = @gen.GenerateContentRequest::new(contents=[
    @gen.Content::new(role="user", parts=[Text(@gen.PartText::new(text=prompt))]),
  ])
  match gemini.generate_content(model=model_id, request) {
    Ok(reply) => Ok(print_text(reply))
    Err(failure) => Err(failure)
  }
}
```

A command-line program builds the client from mttp's backend and clock, and
closes the backend when it is done. Import `gaato/mttp`, `moonbitlang/core/env`
and `moonbitlang/core/debug` in its `moon.pkg`:

```mbt nocheck
///|
fn main {
  @mttp.run(async fn() {
    guard @env.get_env_var("GEMINI_API_KEY") is Some(key) else {
      println("Set GEMINI_API_KEY")
      return
    }
    guard @env.get_env_var("GEMINI_MODEL") is Some(model) else {
      println("Set GEMINI_MODEL to a model your account can use")
      return
    }
    let backend = @mttp.backend()
    defer backend.close()
    let gemini = @gemini.Gemini::new(
      backend,
      @mttp.clock(),
      auth=ApiKey(key),
      timer=@mttp.timer(),
      total_timeout_ms=120_000,
    )
    match generate(gemini, model, "Describe a quiet morning.") {
      Ok(_) => ()
      Err(failure) => println(@debug.to_string(failure))
    }
  })
}
```

`model=` takes a bare ID or a resource name starting with `models/`. **A
successful response can have no text**: when a prompt is blocked, there are no
candidates. Check `prompt_feedback` and each candidate's finish reason before
expecting text.

`auth=` takes `ApiKey(key)` (sent in a header), `ApiKeyInQuery(key)` (in the
URL, so it can appear in logs) or `OAuthToken(token)`. Obtaining an OAuth token
is up to the application. The SDK marks its credential headers even with
`from_client`. Redirects that change host, port or scheme strip them, except
for a same-host HTTP port 80 to HTTPS port 443 upgrade, and HTTPS to HTTP is
refused by default. A key in the query string stays in the URL.

## Stream model output

```mbt check
///|
pub async fn stream(
  gemini : @gemini.Gemini,
  model_id : String,
  request : @gen.GenerateContentRequest,
) -> Result[Unit, @gemini.Failure] {
  gemini.stream_generate_content(model=model_id, request, reply => {
    print_text(reply)
  })
}
```

The callback receives a decoded response for each event. An optional `stop`
predicate closes the stream before delivering the event it matches. An
interrupted stream is not resumed. When you pass model output into a later
turn, keep each part's thought signature and other metadata, which Gemini
needs back.

`list_models`, `list_models_pages` and `get_model` list the models your key
can use and describe one.

## Media, files and cached context

- **Small media:** an `InlineData` part, with the bytes as their base64 wire
  string.
- **Larger files:** `upload_file(bytes, mime_type=..., display_name=...)`, then
  a `FileData` part with the returned file URI. The upload holds the whole input
  in memory and does not resume an interrupted session. A new file can still
  be processing, so check it with `get_file` before generating. `list_files_pages`
  and `delete_file` manage files.
- **Reusable context:** `create_cached_content`, then pass its full resource
  name as `cached_content` in the request. `get_`, `list_`, `update_` and
  `delete_cached_content` manage caches.

File and cache methods accept the names they return (`files/abc`,
`cachedContents/abc`) or the bare ID.

## Retries, deadlines and errors

| Setting | Default with `Gemini::new` | Notes |
| --- | --- | --- |
| Retries | Up to 4, on HTTP 503 and on transport failures known to be unsent | 429 and failures after sending are not retried. `Retry-After` is honoured; a server that asks for more than 60 s is not retried. |
| `timeout_ms`, `total_timeout_ms` | none | Set them, with `timer=`, to bound calls. |
| Buffered body | the runtime's default | `max_body_bytes=` |

`Gemini::from_client` keeps the supplied client's policies instead.

Failures are values of `Failure`. Match with a wildcard arm:

- `Http(...)`: the status, headers, diagnostic bytes, and Google's typed error
  when present.
- `Transport(...)`: the network failed or a deadline expired.
- `Decode(...)`: the response did not match the model.
- `Validation(operation~, parameter~, message~)`: invalid input, caught before
  sending.

An exception raised in a streaming callback reaches the caller unchanged.

## Not included

The Live API, Interactions, tuning, batch jobs and file-search stores.

## Links

- [Changelog](https://github.com/gaato/moonbit-sdks/blob/main/gemini/CHANGELOG.md)
- [Behaviour survey and API coverage](https://github.com/gaato/moonbit-sdks/blob/main/docs/behavior/gemini.md)
- [Repository](https://github.com/gaato/moonbit-sdks)

## License

Apache-2.0
