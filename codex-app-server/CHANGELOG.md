# Changelog

## [Unreleased]

## [0.2.0] - 2026-11-10

### Changed

- **Run sessions on moonbitlang/core/async and the updated JSON-RPC adapter.**
  Handshake, typed events, explicit handlers and shutdown behavior are retained.
  Migration: use core/async's non-generic TaskGroup and BinaryReader/BinaryWriter
  with exact experimental package opt-ins.
