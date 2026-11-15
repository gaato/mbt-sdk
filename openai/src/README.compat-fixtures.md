# Compatible-provider fixtures

All new fixtures are **constructed from documentation**, dated **2026-11-15**,
not recordings or live compatibility evidence. Payloads are ordinary MoonBit
JSON/byte literals in the files below so the portable fake-backend tests use
the exact reviewed fixture values without filesystem or prebuild dependencies.
Provider/model names, IDs, text, token counts and vectors are synthetic.
Each fixture file also carries its source URLs and date.

| Fixture file | Source and coverage |
|---|---|
| `compat_deepseek_test.mbt` | [Chat](https://api-docs.deepseek.com/api/create-chat-completion), [thinking](https://api-docs.deepseek.com/guides/thinking_mode), [models](https://api-docs.deepseek.com/api/list-models), [Responses](https://api-docs.deepseek.com/api/create-response): missing creation time, reasoning/tool round trip, non-stream whitespace, stream reasoning. |
| `compat_dashscope_test.mbt` | [Chat](https://help.aliyun.com/en/model-studio/qwen-api-via-openai-chat-completions), [embeddings](https://help.aliyun.com/en/model-studio/embedding-interfaces-compatible-with-openai), [Responses](https://help.aliyun.com/en/model-studio/compatibility-with-openai-responses-api): empty fingerprint, usage-only final chunk, absent prompt count. |
| `compat_zhipu_test.mbt` | [OpenAI compatibility](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction), [API reference](https://docs.bigmodel.cn/api-reference/): reasoning, sensitive/network_error finish reasons, embeddings. |
| `compat_moonshot_test.mbt` | [Chat](https://platform.kimi.com/docs/api/chat), [models](https://platform.kimi.com/docs/api/list-models), [compatibility](https://platform.kimi.com/docs/guide/migrating-from-openai-to-kimi): nullable reasoning, indexed streamed tools, usage-only chunk, model list. Responses is a minimum-shape hypothesis; the guide lists the endpoint without its schema. |
| `compat_openrouter_test.mbt` | [Overview](https://openrouter.ai/docs/api-reference/overview), [errors](https://openrouter.ai/docs/api-reference/errors), [embeddings](https://openrouter.ai/docs/api-reference/embeddings/create-embeddings): nonempty final usage choices, absent owner/time, numeric errors (also in errors fixture). |
| `compat_ollama_test.mbt` | [Pinned wire types](https://github.com/ollama/ollama/blob/a5864fcb33969705de3c0ebfedf4b2a16c970bcc/openai/openai.go), [compatibility](https://github.com/ollama/ollama/blob/a5864fcb33969705de3c0ebfedf4b2a16c970bcc/docs/api/openai-compatibility.mdx), as cited by the supplied survey: reasoning alias, models, retrieval, embeddings, stateless Responses hypothesis. No local server was called. |
| `compat_errors_test.mbt` | [OpenRouter errors](https://openrouter.ai/docs/api-reference/errors), [Z.AI codes](https://docs.z.ai/api-reference/api-code), [DashScope errors](https://help.aliyun.com/en/model-studio/error-code), [OpenAI errors](https://platform.openai.com/docs/guides/error-codes/api-errors): numeric code, error-in-200, mid-stream envelope and named error, non-transient and transient 429. Generic balance/disabled-account strings are constructed contract cases, not claims of a documented wire code at every provider. |
| `compat_test.mbt` | Shared constructed OpenAI envelope, minimal Responses and usage fixtures; the provider files above identify where the compatible endpoint is documented. Replay includes keepalive comments, EOF without DONE for Responses, and both final-usage shapes. |

DeepSeek doc fetches timed out during this implementation. Its shapes remain
hypotheses from the supplied documentation survey. Ollama Responses and
Moonshot Responses need later live confirmation. DashScope's embedding example
was rechecked: its `usage` contains only `total_tokens`. OpenRouter's numeric
error and SSE rules and Z.AI's 1113/1302/1305/1308/1310 table were rechecked.
