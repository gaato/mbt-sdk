# Test coverage ledger

Native line coverage of the hand-written JSON-RPC and Codex connection modules.
Generated protocol/SDK code and SDK facades are checked by behavior tests.
HTTP implementation coverage belongs to [mttp](https://github.com/gaato/mttp/blob/main/TEST_COVERAGE.md).

Run `moon run scripts/coverage_report.mbtx`. CI runs it after gates. The script
selects local packages, excludes live/badhttp network tests, clears counters and
passes only the measured modules' trace maps to the Coveralls reporter.
Set MOON_CC to a system compiler when the bundled compiler cannot link.

Every uncovered line must have a row with an adequate budget and a reason.
Defensive unreachable arms, platform fallbacks and effects that cannot be
induced safely can be listed; reachable behavior must be tested.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| jsonrpc-async/src/connection.mbt | 5 | pending refactor (in flight): `send` after the writer closed (both checks), a non-positive `timeout_ms`, the catch-all of `call`, and a notification-queue error other than closure. |
| jsonrpc-async/src/dispatch.mbt | 1 | The swallowed failure of sending an internal-error reply after a handler raised: the writer must fail between the handler and the reply. |
| File | Budget | Reason |
| --- | --- | --- |
| File | Budget | Reason |
| --- | --- | --- |
| codex-app-server/src/child.mbt | 6 | not yet tested: `spawn` and `Session::shutdown` need an app-server process; testable with a stub `program~` speaking NDJSON. The JSON-RPC child plumbing itself is tested in jsonrpc-async. |
| codex-app-server/src/handlers.mbt | 4 | not yet tested: `dispatch` routes for file-change, permissions and user-input requests (3) and a handler returning `Err` (1); command approval and decode failures are tested. |
| jsonrpc-async/src/child.mbt | 5 | not yet tested: `shutdown` with `timeout_ms <= 0` (2). Needs a spawn or wait failure: the `errdefer`s that close the pipes when `@process.spawn` raises (2; a nonexistent program may reach them, unverified), and the re-raise of a `wait` failure other than the timeout (1). |
| jsonrpc/src/types.mbt | 2 | not yet tested: `RpcError` decoding of a non-object value and of a non-numeric or out-of-range `code`. |
