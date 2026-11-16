# Shared-spec SDK factory

New sources live at `specs/<provider>/<file>` with one adjacent `SOURCE.md`.
Existing per-module spec paths remain supported; reusing one never copies it.
Every consumer records the same `spec_file`, `spec_url`, `spec_fetch`, and
`generator`. Validation rejects contradictory metadata, and a URL vendored to
two different files, because otherwise daily jobs could race over the source.

An entry may declare an inline selection or `[sdk.selection]`:

```toml
[sdk.selection]
paths = ["/zones/", "/accounts/{account_id}/dns/"]
operations = ["an_explicit_operation_id"]
excludes = [{ operation = "an_unsupported_operation_id", reason = "Reviewed unsupported response union; track in the product survey." }]
```

Path prefixes are literal wire paths, including template braces. Prefixes and
operation IDs form a union; explicit exclusions run last. With no inclusions,
the selection starts from all operations. Each exclusion needs a nonempty
reason. Unknown IDs, unmatched prefixes and an empty result fail, so stale
selectors cannot quietly remove a product. Selection runs after the module's
overlays and Discovery conversion. Without a selection, existing include-all
or overlay-selected generation is preserved. Pin checks inspect the selected
operations, while top-level host and authentication baselines still require
review when they change.

```sh
uv run --with pyyaml --with jsonpath-rfc9535 python tools/new_sdk.py github_repos --from-spec github --paths /repos/
uv run --with pyyaml --with jsonpath-rfc9535 python tools/new_sdk.py another_slice --from-spec github/spec/api.github.com.2022-11-28.yaml --paths /orgs/
uv run --with pyyaml --with jsonpath-rfc9535 python tools/sdks.py census --compile
```

An existing unregistered repository spec path also works with `--from-spec`
when its adjacent `SOURCE.md` supplies the HTTPS Source line. Pass
`--generator discovery` for an unregistered Discovery source. The scaffold
checks its selected census and compiles a scratch module before changing the
ledger. It remains unpublished and does not add a client-policy survey.

`tools/sdks.py matrix` emits one item per distinct watched source and includes
every consumer, including consumers whose own `spec_watch` is false. The job
fetches and re-vendors once. `tools/spec_watch.py` runs generation, interface
refresh, census with compilation, and gates independently for every consumer.
Its PR body records every exit code and bounded log tails; a failure cannot
hide a later module. A previously open PR is retained for review, because
fresh local results do not prove that its older patch is identical.

`census.py --compile` first lowers and emits without diagnostics, then creates
a separate module, resolves that module's own dependencies, and runs
`moon check --target wasm-gc --deny-warn`. `--sdk <name>` uses the actual ledger
selection, overlays, dependency pins and facade configuration. Custom Codex
generation and Discovery use this same compilation gate. Compiler errors are
diagnostics with generated file/line locations; a component pointer is added
when the available compiler context identifies it. Unsupported raw body media
remain explicit notes; compilation is not a claim of provider behavior support.

Detection stays daily; versioning/publication is batched by the weekly release
workflow described in [releasing](release.md).
