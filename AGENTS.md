# AGENTS.md

## Documentation

- A published module's `README.md` is a link to `src/overview.mbt.md`, and
  mooncakes.io shows it as the module page. Write it for a visitor deciding
  whether and how to use the module: what it is, install, a usage example,
  and what a user must know (limits, errors, retries, timeouts, targets).
  Design rationale, internal mechanics, test procedures, migration notes for
  old versions and facts that go stale (model names, operation counts,
  upstream version pins) belong in `docs/` or the CHANGELOG, because the page
  is published with each release and cannot be corrected until the next one.
- Examples in `overview.mbt.md` are `mbt check` blocks so that `moon check`
  breaks when the API changes under them. Use `mbt nocheck` only for code that
  needs a module the package does not depend on (such as
  `@mttp.backend()` in the SDK modules); never add a dependency for
  documentation.
- Links in a published module directory are absolute URLs, because
  mooncakes.io serves those files away from the repository and a relative
  link breaks there.
- `moon run scripts/docs_audit.mbtx --self-test` checks the mechanical rules
  (it runs in `scripts/gates.sh` and CI). The script is shared by every gaato
  MoonBit repository: copy it from `gaato/discord.mbt` rather than editing it
  here, so the repositories keep one set of rules. Repository differences go
  in `scripts/docs_audit.json` and `scripts/docs_audit.allow`.
- A module README is also read raw by coding agents in a user's
  `.mooncakes/`. They copy its examples, take every sentence literally, fill
  what it leaves out with guesses, and read the published text until the next
  release, while the modules it might mention change and get renamed.

## API changes

- When a published function's labelled parameter is renamed or removed, an
  optional one becomes required, or a positional one becomes labelled, keep
  existing calls compiling for one minor release with `#label_migration`
  (`alias=old`, `fill=false`, `fill=true` or `allow_positional=true`) and a
  `msg` naming the new form, and remove the attribute in the next minor
  release. Callers then get a warning instead of a build failure; the
  CHANGELOG still lists the change with its migration note. A renamed or
  removed function keeps a `#deprecated` alias for the same period.
