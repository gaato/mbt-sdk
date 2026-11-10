# Changelog

## [Unreleased]

## [0.2.0]

### Changed

- **Use gaato/mttp/jsonkit for generated model helpers.** The pinned schema,
  typed calls and events are unchanged. Migration: use mttp/jsonkit.Presence
  for optional nullable fields; the retired shared runtime is no longer a
  dependency.
