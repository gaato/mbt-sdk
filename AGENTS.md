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
  `@http_async.AsyncTransport` in the SDK modules); never add a dependency for
  documentation.
- Links in a published module directory are absolute URLs, because
  mooncakes.io serves those files away from the repository and a relative
  link breaks there.
- `moon run scripts/docs_audit.mbtx --self-test` checks the mechanical rules
  (it runs in `scripts/gates.sh` and CI). The script is shared by every gaato
  MoonBit repository: copy it from `gaato/discord.mbt` rather than editing it
  here, so the repositories keep one set of rules. Repository differences go
  in `scripts/docs_audit.json` and `scripts/docs_audit.allow`.
