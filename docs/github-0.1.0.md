# GitHub 0.1.0 release candidate

Publish only `gaato/github@0.1.0`. Its registry dependencies are
`gaato/http@0.1.0` and `gaato/sdk-runtime@0.1.0`; the transport adapter is
caller-supplied and is not a package dependency. The unpublished runtime test
module imports `gaato/github@0.1.0`.

## Scope

- Generate every one of the 1,221 operations in the vendored first-party
  OpenAPI description (`api.github.com.2022-11-28.yaml`) into
  `gaato/github/gen`, as sans-IO `<operation>_request` / `<operation>_decode`
  pairs. This is the first module that generates a whole API rather than a
  chosen slice.
- Ship a thin facade that sends, follows `Link` pages, and reads GitHub's error
  bodies. It does not restate the generated types: at this surface area a
  hand-written mirror would be a second API to keep in step with the first.
- First real consumer of the runtime's `Paginator`, `parse_link_next`,
  `WindowLimiter` and `rate_limit_headers`, which until now only the runtime
  tests exercised.
- `X-GitHub-Api-Version: 2022-11-28` is sent by default and is what the vendored
  document describes. See `github/spec/SOURCE.md` for why that version and not
  the undated or the announced future one.
- Watch the upstream GitHub description alongside OpenAI's and Anthropic's.

## Public API

```moonbit
GitHub::new(transport, clock, token?, base_url?, api_version?, user_agent?, retry?, limiter?)
GitHub::from_client(@runtime.Client)
GitHub::call(request, decode)      // a generated operation, in one line
GitHub::send(request)              // 204 / 304 and non-JSON representations
GitHub::paginator(request, decode) // follows the Link rel="next" URL
ApiErrorBody, api_error, is_not_modified, is_secondary_rate_limit
```

Default headers: `accept: application/vnd.github+json`, `x-github-api-version`,
`user-agent` (GitHub requires one). A request header wins over a client default,
so an operation needing `application/vnd.github.diff`, `.patch` or `.sarif` sets
its own `accept`. Search is metered separately, so `/search/*` uses its own rate
limit bucket. `base_url` points at the REST mount for GitHub Enterprise Server
(`https://ghe.example.com/api/v3`).

## Breaking changes

None: this is a new module.

## Known limitations

- 43 places in the document (24 overlay actions) stay raw `Json` because no rule
  over the payload can pick a union branch — the tag is on a sibling property, or
  the branches are subsets of each other. `docs/census.md` classifies all 43 with
  the reason for each; they can be typed individually later without changing any
  operation signature.
- The generated public types are the upstream schema names and shapes. A change
  to the description is a change to this module's public API; there is no
  compatibility layer as in `gaato/openai`.
- A field that the document declares both required and nullable requires the key
  to be present: an explicit `null` decodes, an absent key does not. A relaying
  proxy that omits nulls will fail to decode. GitHub itself sends them.
- Generated operations never set `accept`; a caller wanting diff, patch or sarif
  sets it on the request.
- No per-operation wrappers (`gh.get_repo(...)`). `call` and `paginator` take the
  generated pair.
- Twelve defects in the upstream description are listed at issue-reporting
  granularity at the end of `docs/design-m8.md`. Three of them cost the most:
  the Contents 200 discriminator (unresolvable in principle), the check-runs POST
  discriminator, and the unions whose tag sits on a sibling property.

## Scope and evidence

The all-operation census reports `operations=1221 diagnostics=0` with both
overlays applied, and `scripts/generate.sh --check` reports no drift. Generated
output is 168,626 + 40,169 lines; a cold `moon -C github check --deny-warn` takes
2.6 s at 527 MB peak RSS, well inside the 60 s budget that decided the scope.

Tests: 13 synchronous in `github/src` (error bodies and the three predicates,
bucket selection and URL normalisation, default headers and their override, the
spec example of `repos/get`), 11 asynchronous in `runtime-tests/src/github`
(`FakeTransport` + `FakeClock`: headers and auth, three `Link` pages, a limiter
wait on `x-ratelimit-remaining: 0`, a 502 retry, 429, 403 + `retry-after`, 304),
and four live checks against the real API (unauthenticated `repos/get`, two
`Link` pages, rate limit observation, a multi-segment `contents/{path}`). The
live suite is opt-in, reads `MBT_SDK_GITHUB_TOKEN`, and is not part of the gates.

The generator changes this module needed (fallback constructor collisions,
`+1`/`-1` variant names, `x-moonbit-path-segments`, a faster YAML loader) also
regenerate OpenAI, Anthropic, Codex and the fixtures. Their output is unchanged
(`scripts/generate.sh --check`), their versions are not bumped, and they are not
being republished.

Pushing the version bump to `main` triggers the existing release workflow after
CI succeeds. Review the candidate diff and publish dry-run before authorizing
that push; no manual publish is needed.
