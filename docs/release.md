# Releasing

Nothing in this repository has been published yet, and publishing is deliberately manual: a mooncakes release cannot be withdrawn, and the account credentials live on the maintainer's machine (`moon login`), not in CI.

## Before the first release

- The module names (`gaato/http`, `gaato/http-async`, `gaato/sdk-runtime`, `gaato/openai`) are provisional until the first publish. Rename now or never.
- Add `repository` and `readme` to every published `moon.mod` once the GitHub repository exists.
- `runtime-tests/` is never published.

## Order

Modules depend on each other by version, so publish bottom-up and only what changed:

1. `gaato/http`
2. `gaato/http-async` and `gaato/sdk-runtime` (both depend on `gaato/http` only)
3. `gaato/openai` (depends on `gaato/http` and `gaato/sdk-runtime`)

## Steps per module

```sh
scripts/gates.sh                 # everything green, including native loopback tests
scripts/generate.sh --check      # generated code is current
# bump `version` in <module>/moon.mod and the `@x.y.z` of dependants' imports
moon -C <module> package --list  # inspect what would be uploaded
moon -C <module> publish --dry-run
moon -C <module> publish
```

Public API changes show up as diffs in `pkg.generated.mbti`; use them to decide the version bump. While versions are `0.x`, a breaking change bumps the minor version.

## After a release

Bump the pinned toolchain image in `.github/workflows/ci.yml` only in its own commit, after `canary.yml` has been green on `:latest`.
