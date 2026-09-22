# openapi.json

- Source: https://openrouter.ai/openapi.json
- Fetched: 2026-09-22
- sha256: 80e4dd0d8230e09051d4e5f47c5e1ad4946230191a15446db12ff740e7c221e0

Census target for M4c (discriminators, 3.1 nullability). Also the live-test backend for gaato/openai and gaato/anthropic (free models). Do not edit by hand.

## Local modification

Example API keys in the upstream document (`sk-or-v1-…` values under `example` fields) are replaced with `sk-or-v1-EXAMPLE`, so the vendored file is not byte-identical to upstream. GitHub push protection rejects the originals. Re-apply after re-vendoring:

```sh
sed -i -E 's/sk-or-v1-[A-Za-z0-9]{20,}/sk-or-v1-EXAMPLE/g' specs/openrouter/openapi.json
```
