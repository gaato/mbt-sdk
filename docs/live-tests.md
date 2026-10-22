# Live tests

The live suite in `runtime-tests/src/live` sends real requests. `scripts/live.sh`
runs it and reads provider settings from the environment or
`~/.config/mbt-sdk/env`. Remote tests make actual provider requests and may
incur charges. A provider without a key is skipped, and a skipped run is not
evidence of compatibility with the official service.

## Anthropic

The opt-in official API tests cover model listing and retrieval, token
counting, buffered and streaming Messages, a tool-result round trip, streamed
tool arguments, and buffered and streaming thinking with signatures. Set
`ANTHROPIC_API_KEY` and run, from the repository root:

```sh
scripts/live.sh --filter 'live Anthropic official *'
```

They use `claude-haiku-4-5` with small output limits (thinking requests allow
1,536 output tokens, including a 1,024-token thinking budget).
