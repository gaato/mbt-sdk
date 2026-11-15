# badhttp fixture behavior

Surveyed 2026-11-15 against the vendored `specs/badhttp/openapi.json`.
This is an offline protocol fixture, not a published provider SDK.

The spec has no authentication. Its pinned server is https://badhttp.dev.
The generated default is mttp_core's conservative retry policy: two retries,
retryable statuses and sent failures restricted to idempotent requests; a
failure proving the request was not processed may retry any method.
No provider-specific retry behavior or timeout is claimed. Tests inject a
backend and clock; no endpoint is contacted by the gates.
