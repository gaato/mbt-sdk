# Changelog

## [Unreleased]

### Changed

- Generated code now qualifies constructor references; no public API change.
- **Regenerated from the upstream spec fetched 2026-11-16** (sha256 `9ef8b554c97e`). Changes are batched for the next weekly release; see the generated interface diff.
- **Build with MoonBit 0.10.21 and mttp_core 0.3.0.** Invalid explicit header values, including surrounding whitespace, return validation failures before I/O.
- **Regenerated from the upstream spec fetched 2026-11-18** (sha256 `f9fc221fdb72`). Changes are batched for the next weekly release; see the generated interface diff.

### Security

- **Mark x-goog-api-key and Authorization on each request.** Caller-owned Clients use the marks for redirect stripping and curl redaction.

### Fixed

- **The README's Install adds every module the examples use** (`gaato/mttp_core` and `gaato/mttp`), and the module has a description on mooncakes.io.

## [0.1.0] - 2026-11-16

First release: a Gemini API client generated from Google's Discovery document
(`generativelanguage` v1beta).

- Content generation, including the SSE stream, embeddings, token counting,
  models, files (with resumable upload) and cached contents.
- `Part` is a union over its data field, so each part carries exactly one kind
  of data.
- Model, file and cache names are accepted as IDs or resource names and checked
  against the API's patterns before a request is sent.
- Retries follow Google's AIP-194: 503 and failures that prove nothing was sent;
  429 is returned at once.
