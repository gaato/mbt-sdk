# Petstore fixture behavior

Surveyed 2026-11-15 against the vendored `specs/petstore3/openapi.json`.
This is an offline OpenAPI fixture, not a published provider SDK.

The server is https://petstore3.swagger.io/api/v3. The description declares
an `api_key` header and an OAuth access token for pet operations. The generated
client accepts an already obtained bearer token; it does not perform OAuth
flows. Operation security chooses which credential applies; public operations
receive no construction-time credentials.

Without a documented provider retry rule the generated client uses mttp_core's
conservative policy. No default timeout is imposed. From mttp_core 0.3.0,
the facade marks `api_key` on each request, including with a supplied Client.
The runtime drops it when the host, port or scheme changes, except for a
same-host HTTP port 80 to HTTPS port 443 upgrade. HTTPS to HTTP is refused
by default. All contract tests use an offline backend.
