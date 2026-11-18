# Live tests

The live suite in `runtime-tests/src/live` sends real requests. `scripts/live.sh`
runs it and reads provider settings from the environment or
`~/.config/moonbit-sdks/env`. Remote tests make actual provider requests and may
incur charges. A provider without a key is skipped, and a skipped run is not
evidence of compatibility with the official service.
The live harness trims surrounding whitespace from credentials loaded from
the environment, including settings sourced by the launcher.

## OpenAI-compatible providers

The additional opt-in tests use `DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY`,
`ZAI_API_KEY` and `MOONSHOT_API_KEY`; each skips when its key is absent.
They check successful decoding of chat, stream, and tools; model listing and
Responses run where documented, embeddings on DashScope and Zhipu. A tool
follow-up runs only if the model actually returns tool calls, and includes the
returned reasoning history. A skipped follow-up is printed explicitly.
There are no assertions about generated text. No `retrieve_model` call is made
to providers that do not document that endpoint.

For each prefix, optional `<PREFIX>_BASE_URL` and `<PREFIX>_MODEL` override
the service and model. `<PREFIX>_EMBEDDING_MODEL` overrides the embedding model.
Presets (2026-11-15, subject to change) are DeepSeek `deepseek-flash`,
DashScope `qwen3.8` / `text-embedding-v4`, Zhipu `glm-4.7-flash` / `embedding-3`,
and Moonshot `kimi-k3.1-pro`. Use your account's available models.

DashScope defaults to the Singapore legacy domain. Prefer
`DASHSCOPE_BASE_URL=https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`
with a Singapore key, or your own workspace/region and its key; region-bound
keys are not interchangeable. Zhipu defaults to the China service at
`https://open.bigmodel.cn/api/paas/v4`; set `ZAI_BASE_URL` and model for an
international Z.AI account. Moonshot defaults to `.ai`; use `MOONSHOT_BASE_URL`
for `.cn` accounts. The compatible-provider section of the OpenAI overview
lists endpoint caveats.

Each test disables retries, bounds each call to 45 s and the provider test to
240 s. Chat/stream/Responses request 16 output tokens; tool generation allows
128 tokens and its follow-up 16. These are real, potentially billable calls
even if decoding fails. A DashScope account with free-quota-only enabled can
prevent paid usage; verify that setting and regional eligibility yourself.
Run only after choosing the account and cost limits, for example:

```sh
scripts/live.sh --filter 'live DeepSeek compatible decoding'
```

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
