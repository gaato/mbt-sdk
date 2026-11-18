# Live tests

The live launcher `scripts/live.sh` runs the `live`, `gemini_live` and
`cloudflare_dns_live` packages in `runtime-tests/src`. It takes provider settings
from the environment and sources `~/.config/moonbit-sdks/env` when present.
Set `MBT_SDK_ENV` to use another file. Remote tests make real requests and may
incur charges. Missing credentials skip the corresponding provider.
Pass `--filter` to select matching tests across all three packages.
The live harness trims surrounding whitespace from credentials loaded from
the environment, including settings sourced by the launcher. SDK failure
diagnostics show the operation, HTTP status when received and up to 2,000
characters of decoded response text. They omit response headers and redact
the harness's environment credentials.

## OpenAI-compatible providers

The additional opt-in tests use `DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY`,
`ZAI_API_KEY`, `MOONSHOT_API_KEY` and `GEMINI_API_KEY`.
They check successful decoding of chat, stream, and tools; model listing and
Responses run where configured, embeddings on DashScope, Zhipu and Gemini. A tool
follow-up runs only if the model actually returns tool calls, and includes the
returned reasoning history. A skipped follow-up is printed explicitly.
There are no assertions about generated text. No `retrieve_model` call is made
to providers that do not document that endpoint.

For each prefix, optional `<PREFIX>_BASE_URL` and `<PREFIX>_MODEL` override
the service and model. `<PREFIX>_EMBEDDING_MODEL` overrides the embedding model.
Presets (2026-11-18, subject to change) are DeepSeek `deepseek-flash`,
DashScope `qwen3.8-flash` / `text-embedding-v4`, Zhipu `glm-4.7-flash` / `embedding-3`,
Moonshot `kimi-k3.1-pro`, and Gemini `gemini-2.5-flash` / `gemini-embedding-001`.
Gemini's beta compatibility test covers chat, streaming, tools, embeddings and
model listing. It checks a tool-result follow-up when the model returns tool
calls. Use `GEMINI_MODEL` if your account lacks the legacy model.
Google says requests for `gemini-2.5-flash` will route to
`gemini-3.5-flash-lite` starting December 1, 2026.
[Google's model availability and deprecation schedule](https://aistudio.google.com/docs/deprecations#gemini-2.5-flash-models)

Set `VOYAGE_API_KEY` for Voyage. Its smoke test sends one text embedding
request with `input_type: "query"` to `https://api.voyageai.com/v1`.
The default model is `voyage-4-lite`. Override it with `VOYAGE_EMBEDDING_MODEL`
and the endpoint with `VOYAGE_BASE_URL`.

DashScope defaults to the Singapore legacy domain. Prefer
`DASHSCOPE_BASE_URL=https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`
with a Singapore key, or your own workspace/region and its key; region-bound
keys are not interchangeable. Zhipu defaults to the China service at
`https://open.bigmodel.cn/api/paas/v4`; set `ZAI_BASE_URL` and model for an
international Z.AI account. Moonshot defaults to `.ai`; use `MOONSHOT_BASE_URL`
for `.cn` accounts. The compatible-provider section of the OpenAI overview
lists endpoint caveats.

Each test disables retries, bounds each call to 45 s and the provider test to
240 s. Chat, streaming, Responses and tool follow-ups use a 16-token output
cap by default. Tool generation allows 128 tokens. The Gemini test uses a
4,096-token cap on each chat request to leave room for thinking and output.
These are real, potentially billable calls
even if decoding fails. A DashScope account with free-quota-only enabled can
prevent paid usage; verify that setting and regional eligibility yourself.
Run only after choosing the account and cost limits, for example:

```sh
scripts/live.sh --filter 'live DeepSeek compatible decoding'
scripts/live.sh --filter 'live Gemini compatible decoding'
scripts/live.sh --filter 'live Voyage compatible embeddings'
```

## OpenRouter Responses

With `OPENROUTER_API_KEY`, the Responses smoke test tries free models. The
stream must end with a decoded `Completed` response. Visible text can come
from an `OutputTextDelta` or from the completed response. The test tries the
next free model after a provider failure, a typed `Error` event, an incomplete
response or a completed response without visible text.

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

## Native Gemini API

Set `GEMINI_API_KEY` for the native Gemini SDK's `count_tokens` smoke test.
`GEMINI_MODEL` overrides the same model preset used by the compatibility test.

```sh
scripts/live.sh --filter 'Gemini live countTokens'
```

## Cloudflare DNS and Zones

Set `CLOUDFLARE_API_TOKEN` to a read-only token with **Zone Read** and **DNS
Read** scoped to one zone, and set `CLOUDFLARE_ZONE_ID` to that zone's ID.
The smoke test reads zone metadata, paginates DNS records, reads DNSSEC and
DNS settings, and exports the zone as BIND text.

```sh
scripts/live.sh --filter 'live Cloudflare DNS and Zones read-only'
```
