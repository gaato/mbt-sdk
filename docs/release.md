# Releasing

A release is a version bump on `main`. `release.yml` runs after `CI` succeeds on `main`, and `scripts/release.sh publish` publishes, bottom-up, every listed module whose `version` is not yet in the mooncakes index. Nothing else triggers a publish, and a commit that bumps nothing publishes nothing.

## Which modules

`PUBLISH_MODULES` in `scripts/release.sh`: `http`, `http-async`, `sdk-runtime`, `openai`, `anthropic`, `github`. `jsonrpc`, `jsonrpc-async`, `codex-protocol` and `codex-app-server` stay unpublished until they have a consumer; `runtime-tests/` is never published.

## Cutting a release

```fish
scripts/release.sh bump http 0.2.0       # sets http/moon.mod and every "gaato/http@…" import
scripts/gates.sh                         # green, including native loopback tests
scripts/release.sh publish --dry-run     # what the job will do
```

Commit, push `main`, and watch the `Release` run. Public API changes show up as diffs in `pkg.generated.mbti`; use them to decide the bump. While versions are `0.x`, a breaking change bumps the minor version.

## Automated releases from spec-watch

`spec-watch.yml` bumps `openai`, `anthropic` and `github` itself when a new upstream spec changes their `src`: a patch when every `pkg.generated.mbti` is unchanged, otherwise the minor version (the next major after `1.0`), because the generated types are `pub(all)` and any public API change can break a caller. A spec change that leaves `src` alone releases nothing. When generation, the gates and CI all pass, it merges the PR and dispatches `release.yml`, since a merge made with `GITHUB_TOKEN` starts no CI run on `main`. Anything that fails leaves the PR open and the run red.

## Credentials

`moon publish` reads `~/.moon/credentials.json` only; there is no token environment variable. The job writes that file from the `MOONCAKES_TOKEN` and `MOONCAKES_USERNAME` secrets of the `mooncakes` environment (restricted to `main`) and removes it afterwards. The token is the one `moon login` stores locally, it has no scope or expiry, and mooncakes offers nothing narrower: a leak allows publishing under the account, and a mooncakes release cannot be withdrawn. Rotate by running `moon login` again and updating the secret.

## After a release

Bump the pinned toolchain image in `ci.yml` and `release.yml` only in its own commit, after `canary.yml` has been green on `:latest`.
