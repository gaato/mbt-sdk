# gaato/gemini

Gemini API client for MoonBit: typed multimodal generation, SSE streaming,
embeddings, token counting, file uploads and context caching. Request and
response types live in `gaato/gemini/gen`. Applications supply an HTTP backend
and clock, or a configured `gaato/mttp_core/client.Client`.

For plain chat, the [gaato/openai client](https://mooncakes.io/docs/gaato/openai)
also works with Gemini's [OpenAI-compatible endpoint](https://ai.google.dev/gemini-api/docs/openai).
Use this module for native files, caching, safety settings, thinking signatures,
grounding metadata and typed media parts.

## Install

```sh
moon add gaato/gemini
```

Import `gaato/gemini`, `gaato/gemini/gen` and `gaato/mttp_core/client`.
With an existing runtime client:

```mbt check
///|
pub async fn generate(
  client : @client.Client,
  api_key : String,
  model_id : String,
) -> Unit {
  let gemini = @gemini.Gemini::from_client(client, auth=ApiKey(api_key))
  let request = @gen.GenerateContentRequest::new(contents=[
    @gen.Content::new(role="user", parts=[
      Text(@gen.PartText::new(text="Describe a quiet morning.")),
    ]),
  ])
  match gemini.generate_content(model=model_id, request) {
    Ok(reply) => println(reply.candidates.unwrap_or([]).length())
    Err(_) => println("Gemini request failed")
  }
}
```

Pass returned resource names straight back: `generate_content(model=...)`
accepts both `gemini-2.5-flash` and `models/gemini-2.5-flash`, producing the same
request. `get_model(name=...)` accepts the same forms. For files,
`get_file(name=...)` takes `files/abc`, as returned in `upload_file`'s
`result.file.name`; a bare `abc` also works. Cache methods similarly accept
`cachedContents/abc` or `abc`. Other resource-name patterns require a complete
name. Invalid names return `Failure::Validation` before any request is sent.
Body fields such as `model`, `cached_content` and file URIs use the full names
required by Gemini.
Header API keys keep credentials out of URLs. `ApiKeyInQuery(key)` query authentication
and `OAuthToken(access_token)` OAuth authentication are alternatives; obtaining an
OAuth token is the application's responsibility.

For an application using `gaato/mttp`:

```mbt nocheck
///|
let gemini = @gemini.Gemini::new(
  @mttp.backend(),
  @mttp.clock(),
  auth=ApiKey(api_key),
)
```

## Streaming and multimodal parts

```mbt check
///|
pub async fn stream(
  gemini : @gemini.Gemini,
  model_id : String,
  request : @gen.GenerateContentRequest,
) -> Unit {
  match
    gemini.stream_generate_content(model=model_id, request, event => {
      for candidate in event.candidates.unwrap_or([]) {
        for
          part in candidate.content
          .map(content => content.parts.unwrap_or([]))
          .unwrap_or([]) {
          match part {
            Text(text) => println(text.text)
            _ => ()
          }
        }
      }
    }) {
    Ok(_) => ()
    Err(_) => println("Stream failed")
  }
}
```

Streaming sets `alt=sse` and decodes each event. An optional typed `stop`
predicate closes the response before delivering its matching event. EOF,
errors and callback exit also close it; interrupted streams are not resumed.

`Part` chooses exactly one data variant. For inline media, use
`InlineData(@gen.PartInlineData::new(inline_data=...))`; for uploaded media,
use `FileData(@gen.PartFileData::new(file_data=...))`. Each payload also accepts
thought signatures, video metadata and other metadata fields. Byte fields use
their wire base64 strings. Preserve thought signatures when echoing model
parts back to Gemini. Unknown data variants require an SDK update.

## Files and cached content

```mbt check
///|
pub async fn upload(gemini : @gemini.Gemini, bytes : Bytes) -> Unit {
  match
    gemini.upload_file(bytes, mime_type="text/plain", display_name="notes") {
    Ok(result) =>
      println(result.file.bind(file => file.uri).unwrap_or("No URI returned"))
    Err(_) => println("Upload failed")
  }
}
```

Uploads start a resumable session and upload/finalize the buffered bytes. They
do not recover interrupted sessions or chunk large inputs. Only session URLs
on the configured origin are accepted. A returned file can still be processing:
use `get_file` to inspect its state before generation. `list_files_pages`
follows page tokens; `delete_file` removes a file.

Use `create_cached_content`, `get_cached_content`, `list_cached_contents_pages`,
`update_cached_content` and `delete_cached_content` to manage caches. Updates
support expiration fields with `update_mask`; generating against a cache uses
the full cache resource name in `GenerateContentRequest.cached_content`.

## Limits, retries and errors

The backend-plus-clock constructor retries HTTP 503 and transport failures that
prove nothing was sent. It does not retry 429 or ambiguous sent failures.
Retries are bounded, use backoff with jitter, and honour `Retry-After` up to
60 seconds. A longer server delay stops retries and returns the HTTP failure.
`RetryInfo` body delays are retained in error details but are not applied by
the generated retry policy. Disable retries when repeating a write could have
unintended effects. `from_client` uses the supplied client's policies instead.

No per-attempt or total timeout is imposed by default. Choose `timeout_ms`,
`total_timeout_ms` and a timer to bound calls; connection limits belong to the
backend. Buffered responses use the runtime's default size limit. File upload
buffers its entire input; service file and project quotas still apply.

Failures are `Http` (operation, status, headers, diagnostic bytes and optional
typed `GoogleError`), `Transport` (kind and phase) or `Decode`. Match with a
default arm. Safety blocking may be a successful response with feedback and
no candidate, so inspect `prompt_feedback` and candidate finish reasons.
Generic `call` decoders return `Result` without raising; streaming callback
exceptions propagate. With `from_client`, add `x-goog-api-key` to the runtime
redirect credential headers yourself. Query keys appear in URLs and logs.

The SDK supports wasm-gc, JavaScript and native; transport support depends on
the backend. It covers the native generateContent API; Live, Interactions,
tuning, batch jobs and file-search stores are outside this module's surface.
See the [behavior survey](https://github.com/gaato/moonbit-sdks/blob/main/docs/behavior/gemini.md)
and [specification source](https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta).

## License

Apache-2.0
