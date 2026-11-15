# Petstore fixture behavior

Surveyed 2026-11-15 against the vendored `specs/petstore3/openapi.json`.
This is an offline OpenAPI fixture, not a published provider SDK.

The server is https://petstore3.swagger.io/api/v3. The description declares
an `api_key` header and an OAuth access token for pet operations. The generated
client accepts an already obtained bearer token; it does not perform OAuth
flows. Operation security chooses which credential applies; public operations
receive no construction-time credentials.

Without a documented provider retry rule the generated client uses mttp_core's
conservative policy. No default timeout is invented. The `api_key` header is
removed on cross-origin redirects by the backend-plus-clock constructor.
Callers supplying their own runtime Client must configure that credential
header themselves. All contract tests use an offline backend.
