# Test coverage ledger

Line coverage of the hand-written modules (`http`, `http-async`, `sdk-runtime`,
`jsonrpc`, `jsonrpc-async`, `codex-app-server`), measured on native with
`moon test --enable-coverage` and reported in Coveralls-JSON mode. The rule is
a closed ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.sh` enforces this: a file with uncovered
> lines must have a row here whose budget is at least the actual count, and
> the script fails otherwise. Rows for fully covered files are flagged as
> stale and rows with slack are noted, so budgets only ever shrink.

## Running it

```fish
scripts/coverage_report.sh                    # measure, print tables, check the ledger
scripts/coverage_report.sh --from-json _build/coverage_report.json   # recheck only
```

CI runs it after the gates on every push and pull request, so a change that
leaves a line unexplained or over budget fails there; it is not part of
`scripts/gates.sh`. A run takes about 13 s on a warm or cold
`_build` (the instrumented test build is from scratch either way) and three
consecutive runs produced identical per-line results, but it opens loopback
sockets and spawns child processes, so it shares the native tests' sandbox
requirements. Exit status: 0 = ledger OK, 1 = an unexplained or over-budget
file, 2 = the run itself failed (a failing test, a build error).

`--from-json` only rechecks a stored report against the ledger; it does not
rerun the tests.

### What is measured

- Sources: every non-test `.mbt` under `<module>/src/` of the six modules.
  Excluded: `codex-app-server/src/examples/` (a demo binary that needs a real
  `codex` install), JS-only files (`*.js.mbt`, never compiled on native), and
  the generated code (`openai`, `anthropic`, `github`, `codex-protocol`,
  fixtures).
- Test drivers: every package of the six modules, plus every `runtime-tests`
  package except `runtime-tests/src/live` and `runtime-tests/src/badhttp`
  (both reach real servers). `runtime-tests` is where
  sdk-runtime's async behaviour runs (sdk-runtime itself cannot depend on
  `moonbitlang/async`); without it `sdk-runtime/src/client.mbt` drops from
  104/119 to 4/119 and `paginator.mbt` to 0/28. The live API tests are left
  out because they need credentials and the network.
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

### Pitfalls the script pins

- `moon coverage analyze` takes no `--target` and, in this `moon.work`
  workspace, tests every member, generated clients included; `moon -C <member>
  test` does the same. The script runs `moon test --target native
  --enable-coverage <package dirs>` from the workspace root instead.
- Left to discover trace maps itself, the reporter loads github's generated
  2.5 MB `.trace.source` and dies with `Fatal error: exception Stack overflow`.
  The script passes the measured modules' trace maps (and counter files)
  explicitly.
- Counters from earlier runs and trace maps of moved or deleted packages
  silently corrupt the merge, so every run deletes `_build/**/moonbit_coverage_*`
  and `_build/native/debug/test` first.
- `-f summary` omits fully covered files, which skews totals; the script uses
  the Coveralls JSON.
- moon's bundled tcc cannot link on some hosts (openSUSE); the script sets
  `MOON_CC=cc` unless it is already set.

Snapshot at the last full measurement (2026-10-18, main at `1468aead`):
**95.1 %** across the measured modules (1172/1232 lines; http 98.7 %,
jsonrpc 98.3 %, http-async 95.8 %, sdk-runtime 95.8 %, jsonrpc-async 88.6 %,
codex-app-server 75.0 %).

## Policy

Must be covered by tests:

- pure logic: header/URL/body assembly, the SSE parser, JSON-RPC framing and
  codecs, multipart, retry and rate-limit arithmetic;
- every `raise` arm reachable through the public API, including the
  transport-error mapping arms (a scripted `@mock.FakeTransport` failure
  reaches each one);
- wire behaviour of `AsyncTransport` and the pool through the loopback
  server tests in `http-async/src/loopback`.

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- platform-only fallbacks that native never takes;
- error arms that need a real I/O failure the loopback and child-process
  tests cannot provoke (a failing pipe, a failing `wait`);
- code under an in-flight refactor, budgeted as `pending refactor (in
  flight)` so the refresh after it merges is mechanical;
- testable lines not yet tested, marked `not yet tested` — these are the
  queue for new tests, not a permanent exemption.

Budgets are exact uncovered counts at the last measurement.

## Accepted uncovered

Pending refactor (in flight; re-measure after the parallel changes merge):

| File | Budget | Reason |
| --- | --- | --- |
| http-async/src/pool.mbt | 3 | Closing the real connections `IdlePool` hands back as expired needs real elapsed time; the `IdlePool` tables cover which ones expire. The `invalid URL` and `unsupported protocol` mapping of `@ahttp.Client` construction errors: `split_url` rejects both before a client is built. |
| http-async/src/transport.mbt | 4 | The `send_stream` errdefer that closes a client opened before the head timed out, the non-`HttpError` arm of `bounded` (callers narrow every error first), and the mapping of a socket error while reading a body, buffered (`read_body`) or streamed (`ClientStream::read_some`): only the network-dependent badhttp tests reach them. |
| sdk-runtime/src/rate_limit.mbt | 7 | Header-window parsing: a remaining count without either reset header (3), an all-whitespace count (1), and the Int64 saturation arms of `decimal_seconds_ms` (3). |
| jsonrpc-async/src/connection.mbt | 6 | pending refactor (in flight): `send` after the writer closed (both checks), a non-positive `timeout_ms`, the catch-all of `call`, a reader failure other than an over-long line, and a notification-queue error other than closure. |
| jsonrpc-async/src/dispatch.mbt | 1 | The swallowed failure of sending an internal-error reply after a handler raised: the writer must fail between the handler and the reply. |

Unreachable or platform-only:

| File | Budget | Reason |
| --- | --- | --- |
| http/src/mock/transport.mbt | 2 | The kind-mismatch arms of `send` and `send_stream`: `take` already rejects a script entry whose kind does not match the call. |

Testable, not yet tested (next candidates):

| File | Budget | Reason |
| --- | --- | --- |
| sdk-runtime/src/client.mbt | 15 | not yet tested: the retry-then-sleep path of `send_stream` (2); the Timeout/Protocol arms of the transport-error mapping in `send_buffered`, `send_streaming` and `read_error_body` (7, Connect is tested); a limiter whose `acquire` raises (1) or whose `release` raises after a transport failure (1) or after a buffered response (the no-op discard, 1); `resolve_url` with no slash on either side (1). Platform-only: the xorshift fallback of `default_random` (2) runs only when `@env.rand` is unavailable, which native never is. |
| codex-app-server/src/child.mbt | 6 | not yet tested: `spawn` and `Session::shutdown` need an app-server process; testable with a stub `program~` speaking NDJSON. The JSON-RPC child plumbing itself is tested in jsonrpc-async. |
| codex-app-server/src/handlers.mbt | 4 | not yet tested: `dispatch` routes for file-change, permissions and user-input requests (3) and a handler returning `Err` (1); command approval and decode failures are tested. |
| jsonrpc-async/src/child.mbt | 5 | not yet tested: `shutdown` with `timeout_ms <= 0` (2). Needs a spawn or wait failure: the `errdefer`s that close the pipes when `@process.spawn` raises (2; a nonexistent program may reach them, unverified), and the re-raise of a `wait` failure other than the timeout (1). |
| http-async/src/mock/virtual_clock.mbt | 3 | not yet tested: `VirtualClock::next_deadline` (no caller in the workspace). |
| jsonrpc/src/types.mbt | 2 | not yet tested: `RpcError` decoding of a non-object value and of a non-numeric or out-of-range `code`. |
| sdk-runtime/src/link.mbt | 2 | not yet tested: a backslash escape inside a quoted Link parameter value. |
| sdk-runtime/src/auth.mbt | 1 | not yet tested: the `Debug` representation of `NoAuth`. |
