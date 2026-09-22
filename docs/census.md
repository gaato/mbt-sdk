# Generator census

2026-09-22 の snapshot。OpenAI all-ops は overlay を適用しない upstream spec、OpenAI included は `openai/overlays/moonbit.yaml` 適用後の 4 操作閉包である。strict rule により、空 schema 以外は明示的な `x-moonbit-json: true` がない限り raw `Json` へ落とさない。

| scope | operations | M4c 前 | M4c 後 | gate |
|---|---:|---:|---:|---|
| badhttp all | 44 | 0 | 0 | zero |
| petstore3 all | 19 | 0 | 0 | zero |
| OpenAI included (`createEmbedding,listModels,retrieveModel,createResponse`) | 4 | — | 0 | zero (`scripts/generate.sh --check`) |
| OpenAI all | 148 | 107 | 35 | report only |
| OpenRouter 4-op closure | 4 | 78 | 13 | report only |
| OpenRouter all | 122 | 813 | 25 | report only |

OpenRouter 4-op の「M4c 前」は `--ops` を追加した時点で初めて計測した値。report-only の再現コマンドは次のとおり。

OpenAI all-ops は調査開始時の 34 から最終的に 35 になった。nested union の flatten により `InputItem` の generic な union 診断 1 件が、実際の `message` discriminator value collision と MoonBit variant name collision の 2 件へ精密化されたためで、未検出の schema が増えたものではない。

```sh
.venv/bin/python tools/gen/census.py openai/spec/openai.yaml openai --derive-operation-ids
.venv/bin/python tools/gen/census.py specs/openrouter/openapi.json openrouter --ops createMessages,createResponses,getModels,createEmbeddings
.venv/bin/python tools/gen/census.py specs/openrouter/openapi.json openrouter
```

## OpenRouter implicit discriminator 調査

候補は `$ref` を解決し、`allOf` を平坦化し、nested `oneOf` / `anyOf` を展開して再検査した。8 箇所とも診断件数は変わらなかった。

| N | JSON pointer | flatten 後に残る理由 |
|---:|---|---|
| 51 | `/components/schemas/Inputs/anyOf/1/items/anyOf` | 共通 `type` はあるが、`message` が候補 2/3/8、`reasoning` が 1/9、`function_call` が 4/10 で衝突 |
| 29 | `/components/schemas/AdditionalToolsItem/properties/tools/items/anyOf` | 28 候補は単一 tag。最後の inline object は required `type: string` だが const/enum がない |
| 17 | `/components/schemas/MessagesContentBlockStartEvent/properties/content_block/anyOf` | 共通 `type` はあるが `compaction` が候補 13 と 17 で衝突 |
| 17 | `/components/schemas/MessagesRequest/properties/tools/items/anyOf` | 候補 13 は非 const `type: string`、候補 14/15 はそれぞれ `type` に 2 alias を持つ |
| 11 | `/components/schemas/BaseInputs/anyOf/1/items/anyOf` | 共通 `type` はあるが `message` が候補 1/2/6 で衝突 |
| 5 | `/components/schemas/OpenAIResponsesToolChoice/anyOf` の object 群 | 1 候補の `type` が `web_search_preview` と dated alias の nested `anyOf` で単一値でない |
| 4 | `/components/schemas/AnthropicUsageIteration/anyOf` | 3 候補は単一 tag。`AnthropicUnknownUsageIteration.type` は自由な `string` |
| 2 | `/components/schemas/FileSearchServerTool/properties/filters/anyOf` | `ComparisonFilter.type` は 6 値、`CompoundFilter.type` は 2 値。集合は非重複だが単一値ではない |

## 残存診断の分類

分類は (a) overlay で raw JSON 境界を明示可能、(b) generator の未実装機能、(c) upstream spec の誤りまたは discriminator 衝突の疑い。ここでは review 用に記録するだけで、OpenAI included 閉包に必要な既存 3 annotation 以外は追加しない。

### OpenAI all-ops: 35

| JSON pointer | kind | class / evidence |
|---|---|---|
| `/components/schemas/CompoundFilter/properties/filters/items/oneOf` | object union N=2 | (b) comparison/compound の `type` は互いに非重複だが複数値。set-valued discriminator は未実装 |
| `/components/schemas/CreateAssistantRequest/properties/tool_resources/properties/file_search/oneOf` | indistinguishable union | (a) 当該 `oneOf` に `x-moonbit-json: true` |
| `/components/schemas/CreateEvalCompletionsRunDataSource/properties/input_messages/oneOf/0/properties/template/items/oneOf` | object union N=2 | (a) 当該 `oneOf` に `x-moonbit-json: true` |
| `/components/schemas/CreateEvalItem/oneOf` | object union N=2 | (a) schema に `x-moonbit-json: true` |
| `/components/schemas/CreateEvalResponsesRunDataSource/properties/input_messages/oneOf/0/properties/template/items/oneOf` | object union N=2 | (a) 当該 `oneOf` に `x-moonbit-json: true` |
| `/components/schemas/CreateEvalRunRequest/properties/data_source/oneOf` | object union N=3 | (a) 当該 `oneOf` に `x-moonbit-json: true` |
| `/components/schemas/CreateResponse/properties/tool_choice/oneOf` | object union N=2 | (a) `CreateResponse.tool_choice` に `x-moonbit-json: true` |
| `/components/schemas/CreateThreadRequest/properties/tool_resources/properties/file_search/oneOf` | indistinguishable union | (a) 当該 `oneOf` に `x-moonbit-json: true` |
| `/components/schemas/EvalRun/properties/data_source/oneOf` | object union N=3 | (a) 当該 `oneOf` に `x-moonbit-json: true` |
| `/components/schemas/Filters/anyOf` | object union N=2 | (a) `Filters` に `x-moonbit-json: true`。included 閉包では既に明示済み |
| `/components/schemas/InputItem` | discriminator value collision | (c) 複数 payload が wire tag `message` を宣言 |
| `/components/schemas/InputItem` | variant name collision | (c) 同じ `message` tag から `Message` が重複 |
| `/components/schemas/Item` | discriminator value collision | (c) 複数 payload が wire tag `message` を宣言 |
| `/components/schemas/Item` | variant name collision | (c) 同じ `message` tag から `Message` が重複 |
| `/components/schemas/ItemResource` | discriminator value collision | (c) 複数 payload が wire tag `message` を宣言 |
| `/components/schemas/ItemResource` | variant name collision | (c) 同じ `message` tag から `Message` が重複 |
| `/components/schemas/RealtimeSessionCreateRequest/properties/modalities` | missing type | (c) `items: {type: string}` はあるが親の `type: array` がない |
| `/components/schemas/RealtimeSessionCreateResponse/properties/modalities` | missing type | (c) `items: {type: string}` はあるが親の `type: array` がない |
| `/components/schemas/RealtimeTranscriptionSessionCreateRequest/properties/modalities` | missing type | (c) `items: {type: string}` はあるが親の `type: array` がない |
| `/components/schemas/RealtimeTranscriptionSessionCreateResponse/properties/modalities` | missing type | (c) `items: {type: string}` はあるが親の `type: array` がない |
| `/components/schemas/Response/properties/tool_choice/oneOf` | object union N=2 | (a) `Response.tool_choice` に `x-moonbit-json: true` |
| `/components/schemas/ResponseProperties/properties/tool_choice/oneOf` | object union N=2 | (a) `ResponseProperties.tool_choice` に `x-moonbit-json: true`。included 閉包では既に明示済み |
| `/components/schemas/Tool/oneOf/2` | discriminator mismatch | (c) mapping は `web_search_preview_tool`、payload `type` は `web_search_preview` と dated alias の 2 値 |
| `/components/schemas/TranscriptTextDeltaEvent/properties/logprobs/items/properties/bytes/items` | array without items | (c) `bytes` は array だが item schema が空 |
| `/components/schemas/TranscriptTextDoneEvent/properties/logprobs/items/properties/bytes/items` | array without items | (c) `bytes` は array だが item schema が空 |
| `/components/schemas/VectorStoreSearchRequest/properties/filters/oneOf` | object union N=2 | (b) comparison/compound の複数値 `type` 集合による discriminator は未実装 |
| `/paths/~1audio~1transcriptions/post/requestBody/content` | multipart | (b) multipart request emission |
| `/paths/~1audio~1transcriptions/post/responses/200/content/application~1json/schema/oneOf` | object union N=2 | (a) response schema に `x-moonbit-json: true` |
| `/paths/~1audio~1translations/post/requestBody/content` | multipart | (b) multipart request emission |
| `/paths/~1audio~1translations/post/responses/200/content/application~1json/schema/oneOf` | object union N=2 | (a) response schema に `x-moonbit-json: true` |
| `/paths/~1files/post/requestBody/content` | multipart | (b) multipart request emission |
| `/paths/~1fine_tuning~1jobs/get/parameters/2` | deepObject query | (b) `style=deepObject, explode=true` serialization |
| `/paths/~1images~1edits/post/requestBody/content` | multipart | (b) multipart request emission |
| `/paths/~1images~1variations/post/requestBody/content` | multipart | (b) multipart request emission |
| `/paths/~1uploads~1{upload_id}~1parts/post/requestBody/content` | multipart | (b) multipart request emission |

### OpenRouter 4-op closure: 13

| JSON pointer | kind | class / evidence |
|---|---|---|
| `/components/schemas/AdditionalToolsItem/properties/tools/items/anyOf` | object union N=29 | (c) 28 候補は single tag、1 inline 候補の required `type` は const/enum なし |
| `/components/schemas/AnthropicUsageIteration/anyOf` | object union N=4 | (b) 3 known tags と自由文字列 `Unknown` payload を併用する open tagged union |
| `/components/schemas/BaseInputs/anyOf/1/items/anyOf` | object union N=11 | (c) `message` tag が 3 候補で衝突 |
| `/components/schemas/FileSearchServerTool/properties/filters/anyOf` | object union N=2 | (b) 6 値対 2 値の set-valued discriminator |
| `/components/schemas/FusionPlugin/properties/tools/items/properties/parameters/additionalProperties/anyOf` | overlapping shape union | (a) `additionalProperties` value schema に `x-moonbit-json: true` |
| `/components/schemas/ImageGenerationServerToolConfig/additionalProperties` | fixed properties plus typed map | (b) fixed fieldsとtyped additionalProperties の同居表現 |
| `/components/schemas/Inputs/anyOf/1/items/anyOf` | object union N=51 | (c) `message`、`reasoning`、`function_call` tag がそれぞれ複数候補で衝突 |
| `/components/schemas/McpServerTool/properties/require_approval/anyOf` | overlapping shape union | (a) `require_approval` に `x-moonbit-json: true` |
| `/components/schemas/MessagesContentBlockStartEvent/properties/content_block/anyOf` | object union N=17 | (c) `compaction` tag が 2 候補で衝突 |
| `/components/schemas/MessagesRequest/properties/tools/items/anyOf` | object union N=17 | (c) 1 候補は非 const `type`、2 候補は `type` に 2 alias |
| `/components/schemas/OpenAIResponsesToolChoice/anyOf` | object union N=5 | (b) web-search payload の `type` が current/dated alias の複数値 |
| `/components/schemas/OpenAIResponsesToolChoice/anyOf` | overlapping shape union | (b) 3 string choices と 5 object choices を畳む heterogeneous union |
| `/components/schemas/WebSearchPlugin/properties/user_location/allOf/1` | non-object allOf member | (b) `$ref` に annotation-only `description/example/required` schema を合成する処理 |

OpenAI 35 件の内訳は (a) 13、(b) 9、(c) 13。OpenRouter 4-op 13 件の内訳は (a) 2、(b) 6、(c) 5。

## Generated size and cold check

`openai/src/gen` は合計 **7,770 行**。内訳は `types.mbt` 5,963、`operations.mbt` 118、`generated_test.mbt` 223、`pkg.generated.mbti` 1,458、`moon.pkg` 8。15,000 行の監視閾値を下回る。

`moon clean` の直後に実行した `moon -C openai check --target wasm-gc` は **0.27 秒** (`/usr/bin/time` の wall time、28 tasks)。
