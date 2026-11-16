# Changelog

## [Unreleased]

- Add typed Gemini generation, SSE, embeddings, token counting, model discovery,
  files and context caching through a generated client facade.
- Add buffered resumable-session upload with start and upload/finalize.
- Enforce one Part data variant while preserving typed metadata siblings.
- Retry 503 and proven-unsent transport failures; honour Retry-After, surface
  429 immediately, and leave timeouts to the application. RetryInfo body delays
  are retained in errors but not interpreted for retries.
- Accept canonical resource names and bare IDs for simple collection patterns;
  reject unsafe names as Validation failures before building a request.
- Return Unit for empty protobuf responses, name authentication variants ApiKey,
  ApiKeyInQuery and OAuthToken, and expose GoogleErrorStatus for RPC errors.
- Treat omitted pagination arrays as empty pages; stop retries when Retry-After
  exceeds 60 seconds.
