# Changelog

## [Unreleased]

## [0.2.0]

### Changed

- **Run connections and native child processes on moonbitlang/core/async.**
  Cancellation, deadlines, bounded dispatch and shutdown behavior are retained.
  Migration: import the core/async packages with exact experimental opt-ins;
  pass BinaryReader/BinaryWriter, use the non-generic TaskGroup and pass
  ProcessOutput values for stderr.
