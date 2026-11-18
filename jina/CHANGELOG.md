# Changelog

## [Unreleased]

- Scaffold generated API vocabulary.

### Changed

- **Build with MoonBit 0.10.21 and mttp_core 0.3.0.** Invalid explicit header values, including surrounding whitespace, return validation failures before I/O.

### Security

- **Mark bearer credentials on each request.** The mark also enables redirect stripping and curl redaction with a caller-owned Client.
