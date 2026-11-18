# Changelog

## [Unreleased]

### Changed

- **Build with mttp_core 0.3.0 and MoonBit 0.10.21.** The regenerated codec interfaces use the canonical JSON decode context name.

## [0.2.0] - 2026-11-10

### Changed

- **Use gaato/mttp/jsonkit for generated model helpers.** The pinned schema,
  typed calls and events are unchanged. Migration: use mttp/jsonkit.Presence
  for optional nullable fields; the retired shared runtime is no longer a
  dependency.
