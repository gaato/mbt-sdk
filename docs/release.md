# Releasing

A release is a version bump on `main`. `release.yml` publishes explicit human
bumps after `CI` succeeds on `main`, and prepares automatic batches on Mondays
at 00:20 UTC. Manual dispatch releases the current batch now. In every case,
`scripts/release.sh publish` works bottom-up and skips versions already in the
Mooncakes index. Daily spec-watch merges never bump versions or dispatch release.

## Which modules

`sdks.toml` is the single registration ledger. `scripts/release.sh` reads its
`publish = true` entries in ledger order: dependencies must precede consumers.
Run `uv run --with pyyaml --with jsonpath-rfc9535 python tools/sdks.py sync` after registration changes; gates check the derived files.

<!-- BEGIN sdks: publish -->
Published modules (ledger order): `openai`, `anthropic`, `github`, `gemini`.

Generated modules kept unpublished: `fixtures/gen/badhttp`, `fixtures/gen/petstore3`, `codex-protocol`, `jina`, `replicate`.
<!-- END sdks: publish -->

`jsonrpc`, `jsonrpc-async` and `codex-app-server` also remain unpublished until
they have a consumer; `runtime-tests/` is never published.

## Changelogs

Each published module has a `CHANGELOG.md` next to its `moon.mod`, so it ships with the module. The format is [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/): an entry is a bold one-sentence summary followed by why it matters, grouped under `### Added`, `### Changed`, `### Removed` or `### Fixed`, and a breaking change ends with a `Migration:` note.

Write the entry in the PR that makes the change, under `## [Unreleased]` of every module whose shipped behaviour or API it changes, including a module that only moves to a new dependency version. A prepared migration may leave an undated version heading; it is dated at release. Normally `scripts/release.sh bump` turns the `[Unreleased]` entries into `## [<version>] - <date>` (today's date) and leaves an empty `[Unreleased]` above them. It warns when there was nothing to move. `scripts/release.sh check`, run by `gates.sh`, fails when a published module has no changelog, when `[Unreleased]` is not its first section, or when the version in `moon.mod` has no heading.

## Cutting a release

```sh
scripts/release.sh bump openai 0.7.0     # sets the module and sibling pins, dates the CHANGELOG
scripts/gates.sh                         # green, including native loopback tests
moon run scripts/coverage_report.mbtx    # ledger OK (CI runs it too; see TEST_COVERAGE.md)
scripts/release.sh publish --dry-run     # what the job will do
```

A structure that grows with network or peer input needs a row in [RESOURCE_BOUNDS.md](../RESOURCE_BOUNDS.md) before it ships; check that the ledger still matches the code being released. An enforced limit's row names the tests that check its bound, and `scripts/bounds_check.mbtx` (run by `gates.sh`) fails when a row names none or names a test that does not exist.

Commit, push `main`, and watch the `Release` run. Public API changes show up as diffs in `pkg.generated.mbti`; use them to decide the bump. While versions are `0.x`, a breaking change bumps the minor version.

## Automated releases from spec-watch

`spec-watch.yml` still detects changes daily. Its matrix has one job per shared
spec, fetching and re-vendoring once, and generating/gating every consumer. A PR
lists each module's generation, interface, census-with-compile and gates results.
All consumers and exact-head CI must pass before auto-merge. A failure leaves
the PR for review. Host/authentication changes still require pin review.

Successful regeneration that changes shipped source adds a note under each
affected module's `[Unreleased]` using `scripts/release.sh note`. It makes no
version bump. Several daily changes are therefore included in one release.
See [the factory](sdk-factory.md) for shared-spec selection and provenance.

The Monday job applies to every published `spec_watch = true` module: OpenAI,
Anthropic, GitHub and Gemini. `tools/weekly_release.py prepare` selects modules
with nonempty `[Unreleased]` entries and compares all relative
`pkg.generated.mbti` paths and hashes with their last published baseline. An API
change gets a minor bump; otherwise it gets a patch, using
`scripts/release.sh bump` to update sibling imports and date the changelog.
This minor/patch rule also applies after 1.0, as specified by the factory's
batch-release policy; a human can explicitly choose a different bump.

Baselines live in `.release-baselines/<ledger-name>.json`: module identity,
version, registry artifact checksum, publication timestamp and the package's
shipped interface hashes. They were bootstrapped from actual published packages,
not from an assumed historical checkout. Before planning, `refresh` compares the
registry index and downloads any newly published immutable package to record its
interfaces. An absent or empty module index is valid before its first release:
`refresh` records `{ "module": "<module>", "state": "unpublished" }` without
inventing published API hashes. The weekly batch releases that module at its
current version, including a human-chosen initial version. It invokes
`scripts/release.sh bump` with that same version to prepare the CHANGELOG; no
version increment is made. The CI-triggered explicit-release path also proceeds
after this refresh. After publication, refresh replaces the unpublished state
with the actual registry artifact's baseline.

A module without a refreshed state file is skipped with a diagnostic asking for
`refresh`, so it cannot prevent other modules from being prepared. Incomplete
published baselines still fail validation instead of guessing patch. If the
local index loses an entry, refresh retains an existing published baseline
rather than treating a previously published module as new. Refresh also
recovers if publication succeeded but the later baseline commit failed.

A scheduled retry skips modules already published in the same **UTC ISO week**.
Manual dispatch bypasses that cadence check; an already explicit human version
bump is preserved and continues through the ordinary CI-triggered publication.
No-change modules are skipped. Baseline/API validation for every candidate runs
before the first bump. The batch runs full gates, including native tests, before
its bump commit is pushed and published. A concurrent main update makes that
push fail before publication; it never force-pushes.

After successful publication, `refresh` records the actual registry artifacts
and commits their baselines. It never records a newer main checkout's API as
the baseline for an older CI-validated commit. Publication and preparation share
one workflow concurrency group. The next refresh repairs an interrupted baseline
recording step from the registry without republishing the same version.

Local inspection (no publish):

```sh
moon update
uv run --with pyyaml --with jsonpath-rfc9535 python tools/weekly_release.py refresh
uv run --with pyyaml --with jsonpath-rfc9535 python tools/weekly_release.py prepare --dry-run
```

## Credentials

`moon publish` reads `~/.moon/credentials.json` only; there is no token environment variable. The job writes that file from the `MOONCAKES_TOKEN` and `MOONCAKES_USERNAME` secrets of the `mooncakes` environment (restricted to `main`) and removes it afterwards. The token is the one `moon login` stores locally, it has no scope or expiry, and mooncakes offers nothing narrower: a leak allows publishing under the account, and a mooncakes release cannot be withdrawn. Rotate by running `moon login` again and updating the secret.

## After a release

Bump the pinned toolchain image in `ci.yml`, `release.yml` and `spec-watch.yml` together, after `canary.yml` has been green on `:latest`.

Update `moonbit-version` alongside the images. The gates require byte-for-byte
matching formatting, generated sources, and interfaces on the pinned compiler.
Run `scripts/generate.sh` and `moon info` with that compiler.
