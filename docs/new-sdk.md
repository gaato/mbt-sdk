# Adding an SDK: matching the official behaviour

An SDK built here should behave the way users of the API expect: it retries what the vendor's own SDK retries, waits as long as the server asks, and paces itself the way the server's documentation says. This checklist is how to find that out for a new API before choosing a runtime preset. The reasoning behind it is in [design-m10.md](design-m10.md).

It deliberately records no current values. Constants, versions and status lists change upstream; they belong in the per-SDK note (`docs/behavior/<sdk>.md`), pinned to a commit and dated.

## 1. Classify every source

Every fact you collect gets one of three labels, and the label decides how much weight it carries:

- **A — the server's contract.** The API's own documentation: rate-limit pages, error and status-code references, idempotency-key documentation, "best practices" pages. Always followed. If our behaviour contradicts it, that is a bug.
- **B — the vendor's official SDK.** Written by the people who run the server, so its retry and timeout choices encode what the server tolerates. Followed unless it contradicts A; when it does, A wins and the note says so.
- **C — community libraries.** Widely used unofficial clients. Reference only: useful to see what users are accustomed to and to spot traps, never a reason by itself.

An API with no official SDK has no B. Do not promote the most popular community library to B.

## 2. Read the server contract (A)

Look for, and quote verbatim in the note:

- How rate limits are signalled: status codes (429, but also 403 or even 200 for some APIs), headers (`Retry-After`, `*-ratelimit-remaining`/`-reset`, bucket or scope headers), and body fields that carry the delay.
- What to do after a limit: wait for the header, a minimum wait, exponential backoff on repeats, a point after which to give up.
- Limits that are not per-request: concurrency, minimum spacing between writes, account-wide or IP-wide limits, penalties for invalid requests.
- Which statuses the docs call transient (often a single line in a status-code table).
- Idempotency: is there an idempotency-key header, a nonce, or any other way to make a resent write safe? If not, a resent POST may duplicate a side effect.

Traps:

- Rate-limit documentation is often split across REST, GraphQL and "best practices" pages that disagree in detail. Read all of them.
- Some limits are reported with HTTP 200 and an error in the body (GraphQL APIs especially). A rule that looks only at status codes misses them.
- Docs pages have no commit to pin. Quote the sentence and date the note.

## 3. Read the official SDK (B)

Find the code that decides retries, not the README. Where to look:

- **Stainless-generated SDKs** (many API vendors use Stainless): `_base_client.py` (`_should_retry`, `_should_retry_exception`, `_calculate_retry_timeout`, `_parse_retry_after_header`, the request loop's `except` branches) and `_constants.py` (default retries, delays, timeouts, any Retry-After cap). The TypeScript and Go SDKs have equivalents; one language is enough unless they disagree.
- **Plugin-based SDKs** (for example octokit): the retry and throttling plugins, and the top-level package that decides which plugins are on by default and with which handlers.
- Otherwise: search the repository for `retry`, `backoff`, `Retry-After`, `timeout`, `429`.

Record for each item: retried statuses, retried methods (is POST excluded?), retried transport failures (timeouts, connection resets, failures before vs after sending), server-delay headers and their order, what happens when the server delay is above a cap (stop, clip, or fall back to backoff), the backoff formula and jitter, the retry count, default timeouts (total and connect), any header that overrides the decision (for example `x-should-retry`), and any pacing or concurrency control.

Traps:

- Two SDKs from the same generator can still differ, for example in the Retry-After cap. Read each vendor's SDK, not one per generator.
- A cap check can sit in the "should retry" function rather than in the delay calculation. Read both before concluding whether a long Retry-After stops or falls back.
- Defaults set in the top-level package can override the plugin's own defaults.
- Pin every link to a commit SHA (`gh api repos/<owner>/<repo>/commits/HEAD --jq .sha`) and re-check line numbers at that SHA.

## 4. Read community libraries (C), if any

Only to learn what users expect and to find traps the docs do not mention. Note where they contradict A.

Trap: a community library's heuristic (for example "a 429 without a JSON body is the CDN's") can slip into our rules as if it were the API's contract. Before adopting one, restate it in A's terms (what the server documents about its own responses and limits) and name the rule after that; mention the infrastructure only as an example of where such a response comes from.

## 5. Choose the runtime configuration

- Start from the sdk-runtime preset closest to B: the Stainless-style preset for Stainless SDKs (set its Retry-After cap to match the vendor), the conservative default when there is no B.
- Adjust the `RetryRule` fields rather than writing code: statuses and the methods each applies to, whether sent failures are retried, the override header, the Retry-After source and cap, the backoff.
- Write a `RetryDecider` only for what a rule cannot express: delays read from a body, special limit types detected from messages, waits that must exceed the general cap.
- Rate limits: configure `WindowLimiter` with the API's headers (`rate_limit_headers`), and use `pace`, `server_key` and `scope` for spacing, server-assigned bucket ids and limit scopes. Do not hard-code limits the server reports in headers.
- Timeouts: expose the vendor's default per-call timeout through `Timeouts`, and document the connect timeout as a transport setting.
- Where B is unsafe for us (for example it resends writes that have no idempotency key), keep the safer behaviour, and record the decision and the reason in the note.

## 6. Record it

Write `docs/behavior/<sdk>.md` with: the date, the sources with their A/B/C labels and pinned links, a table of the official behaviour with a source per row, our behaviour, and a table of divergences with the label and what we adopt. Put the user-visible consequences into the module's CHANGELOG under `[Unreleased]`, with a `Migration:` note when existing callers see a change.
