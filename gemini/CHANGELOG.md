# Changelog

## [Unreleased]

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
