# Changelog

## [Unreleased]

### Changed

- **Adopt MoonBit 0.10.21 IO traits.** The new reader and writer implementations are now in the regular test tree.

## [0.2.0] - 2026-11-10

### Changed

- **Run connections and native child processes on moonbitlang/core/async.**
  Cancellation, deadlines, bounded dispatch and shutdown behavior are retained.
  Migration: import the core/async packages with exact experimental opt-ins;
  pass BinaryReader/BinaryWriter, use the non-generic TaskGroup and pass
  ProcessOutput values for stderr.
