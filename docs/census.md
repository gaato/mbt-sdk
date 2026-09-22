# Generator census

2026-09-22 の snapshot。OpenAI all-ops は overlay を適用しない upstream spec、OpenAI included は `openai/overlays/moonbit.yaml` 適用後の 4 操作閉包である。strict rule により、空 schema 以外は明示的な `x-moonbit-json: true` がない限り raw `Json` へ落とさない。

| scope | operations | M4c 前 | M4e 前 | M4e 後 | gate |
|---|---:|---:|---:|---:|---|
| badhttp all | 44 | 0 | 0 | 0 | zero |
| petstore3 all | 19 | 0 | 0 | 0 | zero |
| OpenAI included (`createEmbedding,listModels,retrieveModel,createResponse`) | 4 | — | 0 | 0 | zero (`scripts/generate.sh --check`) |
| OpenAI all | 148 | 107 | 35 | 30 | report only |
| OpenRouter 4-op closure | 4 | 78 | 13 | 14 | report only |
| OpenRouter all | 122 | 813 | 25 | 25 | report only |
| OpenRouter `createMessages` attempt | 1 | — | 6 | 5 | excluded; report only |

OpenRouter 4-op の「M4c 前」は `--ops` を追加した時点で初めて計測した値。report-only の再現コマンドは次のとおり。

M4e で OpenAI は 35 → 30。`Item` と `ItemResource` の tag / variant-name collision 4 件と `InputItem` の variant-name collision 1 件が解消した。upstream の `InputItem` は required 集合が同じ 2 payload が残るため診断 1 件を維持し、include 済み閉包だけ `x-moonbit-order` で順序を明示した。OpenRouter 4-op は 13 → 14: `BaseInputs` は解消した一方、`Inputs` の generic 診断 1 件が、残る `custom_tool_call` / `message` / `reasoning` の 3 件へ精密化された。

```sh
.venv/bin/python tools/gen/census.py openai/spec/openai.yaml openai --derive-operation-ids
.venv/bin/python tools/gen/census.py specs/openrouter/openapi.json openrouter --ops createMessages,createResponses,getModels,createEmbeddings
.venv/bin/python tools/gen/census.py specs/openrouter/openapi.json openrouter
```

## OpenRouter implicit discriminator 調査

候補は `$ref` を解決し、`allOf` を平坦化し、nested `oneOf` / `anyOf` を展開して再検査した。M4e 後の状態は次のとおり。

| N | JSON pointer | flatten 後に残る理由 |
|---:|---|---|
| 51 | `/components/schemas/Inputs/anyOf/1/items/anyOf` | `function_call` は required 順で解消。`custom_tool_call` / `message` / `reasoning` は required 集合が同じ候補が残る |
| 29 | `/components/schemas/AdditionalToolsItem/properties/tools/items/anyOf` | 28 候補は単一 tag。最後の inline object は required `type: string` だが const/enum がない |
| 17 | `/components/schemas/MessagesContentBlockStartEvent/properties/content_block/anyOf` | `compaction` 2 候補の required 集合が同じため、なお曖昧 |
| 17 | `/components/schemas/MessagesRequest/properties/tools/items/anyOf` | 候補 13 は非 const `type: string`、候補 14/15 はそれぞれ `type` に 2 alias を持つ |
| 11 | `/components/schemas/BaseInputs/anyOf/1/items/anyOf` | resolved: `message` 候補を required 包含と spec 順で決定可能 |
| 5 | `/components/schemas/OpenAIResponsesToolChoice/anyOf` の object 群 | 1 候補の `type` が `web_search_preview` と dated alias の nested `anyOf` で単一値でない |
| 4 | `/components/schemas/AnthropicUsageIteration/anyOf` | 3 候補は単一 tag。`AnthropicUnknownUsageIteration.type` は自由な `string` |
| 2 | `/components/schemas/FileSearchServerTool/properties/filters/anyOf` | `ComparisonFilter.type` は 6 値、`CompoundFilter.type` は 2 値。集合は非重複だが単一値ではない |

## 残存診断の分類

分類は (a) overlay で raw JSON 境界を明示可能、(b) generator の未実装機能、(c) upstream spec の誤りまたは discriminator 衝突の疑い。ここでは review 用に記録するだけで、include 済み閉包または bounded attempt に必要な理由付き annotation 以外は追加しない。

### OpenAI all-ops: 30

| JSON pointer | kind | class / evidence |
|---|---|---|
| `/components/schemas/CompoundFilter/properties/filters/items/oneOf` | object union N=2 | (b) comparison/compound の `type` は互いに非重複だが複数値。set-valued discriminator は未実装 |
| `/components/schemas/CreateAssistantRequest/properties/tool_resources/properties/file_search/oneOf` | indistinguishable union | (a) 当該 `oneOf` に `x-moonbit-json: true` |
| `/components/schemas/CreateEvalCompletionsRunDataSource/properties/input_messages/oneOf/0/properties/template/items` | equal required sets for `message` | (a) 当該 union に `x-moonbit-order`、raw JSON が意図なら `x-moonbit-json` |
| `/components/schemas/CreateEvalItem/oneOf` | object union N=2 | (a) schema に `x-moonbit-json: true` |
| `/components/schemas/CreateEvalResponsesRunDataSource/properties/input_messages/oneOf/0/properties/template/items/oneOf` | object union N=2 | (a) 当該 `oneOf` に `x-moonbit-json: true` |
| `/components/schemas/CreateEvalRunRequest/properties/data_source` | equal required sets for `completions` | (a) 当該 union に `x-moonbit-order`、raw JSON が意図なら `x-moonbit-json` |
| `/components/schemas/CreateResponse/properties/tool_choice/oneOf` | object union N=2 | (a) `CreateResponse.tool_choice` に `x-moonbit-json: true` |
| `/components/schemas/CreateThreadRequest/properties/tool_resources/properties/file_search/oneOf` | indistinguishable union | (a) 当該 `oneOf` に `x-moonbit-json: true` |
| `/components/schemas/EvalRun/properties/data_source` | equal required sets for `completions` | (a) 当該 union に `x-moonbit-order`、raw JSON が意図なら `x-moonbit-json` |
| `/components/schemas/Filters/anyOf` | object union N=2 | (a) `Filters` に `x-moonbit-json: true`。included 閉包では既に明示済み |
| `/components/schemas/InputItem` | equal required sets for `message` | (c) `EasyInputMessage` / `InputMessage` は required が同一。included 閉包では理由付き `x-moonbit-order` 済み |
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

### OpenRouter 4-op closure: 14

| JSON pointer | kind | class / evidence |
|---|---|---|
| `/components/schemas/AdditionalToolsItem/properties/tools/items/anyOf` | object union N=29 | (c) 28 候補は single tag、1 inline 候補の required `type` は const/enum なし |
| `/components/schemas/AnthropicUsageIteration/anyOf` | object union N=4 | (b) 3 known tags と自由文字列 `Unknown` payload を併用する open tagged union |
| `/components/schemas/FileSearchServerTool/properties/filters/anyOf` | object union N=2 | (b) 6 値対 2 値の set-valued discriminator |
| `/components/schemas/FusionPlugin/properties/tools/items/properties/parameters/additionalProperties/anyOf` | overlapping shape union | (a) `additionalProperties` value schema に `x-moonbit-json: true` |
| `/components/schemas/ImageGenerationServerToolConfig/additionalProperties` | fixed properties plus typed map | (b) fixed fieldsとtyped additionalProperties の同居表現 |
| `/components/schemas/Inputs/anyOf/1/items` | equal required sets for `custom_tool_call` | (c) 同じ tag / required 集合の payload が残る |
| `/components/schemas/Inputs/anyOf/1/items` | equal required sets for `message` | (c) 同じ tag / required 集合の payload が残る |
| `/components/schemas/Inputs/anyOf/1/items` | equal required sets for `reasoning` | (c) 同じ tag / required 集合の payload が残る |
| `/components/schemas/McpServerTool/properties/require_approval/anyOf` | overlapping shape union | (a) `require_approval` に `x-moonbit-json: true` |
| `/components/schemas/MessagesContentBlockStartEvent/properties/content_block` | equal required sets for `compaction` | (c) 同じ tag / required 集合の payload が残る |
| `/components/schemas/MessagesRequest/properties/tools/items/anyOf` | object union N=17 | (c) 1 候補は非 const `type`、2 候補は `type` に 2 alias |
| `/components/schemas/OpenAIResponsesToolChoice/anyOf` | object union N=5 | (b) web-search payload の `type` が current/dated alias の複数値 |
| `/components/schemas/OpenAIResponsesToolChoice/anyOf` | overlapping shape union | (b) 3 string choices と 5 object choices を畳む heterogeneous union |
| `/components/schemas/WebSearchPlugin/properties/user_location/allOf/1` | non-object allOf member | (b) `$ref` に annotation-only `description/example/required` schema を合成する処理 |

OpenAI 30 件の内訳は (a) 13、(b) 9、(c) 8。OpenRouter 4-op 14 件の内訳は (a) 2、(b) 6、(c) 6。

### OpenRouter `createMessages` の bounded attempt

`specs/openrouter/overlays/moonbit.yaml` で一度 include し、(a) の `FusionPlugin.tools[].parameters.additionalProperties` だけを理由付き `x-moonbit-json: true` にした。残るため exclude に戻した blocker は次の 5 件。

| JSON pointer | class / blocker |
|---|---|
| `/components/schemas/AnthropicUsageIteration/anyOf` | (b) known tag 3 種と自由文字列 `Unknown` payload の併用 |
| `/components/schemas/ImageGenerationServerToolConfig/additionalProperties` | (b) fixed properties と typed additionalProperties の同居 |
| `/components/schemas/MessagesContentBlockStartEvent/properties/content_block` | (c) `compaction` 2 候補の required 集合が同じ |
| `/components/schemas/MessagesRequest/properties/tools/items/anyOf` | (c) 非 const `type` 1 候補と複数 alias `type` 2 候補 |
| `/components/schemas/WebSearchPlugin/properties/user_location/allOf/1` | (b) `$ref` への annotation-only allOf member |

## Generated size and cold check

`openai/src/gen` は M4e 後に合計 **10,468 行**。内訳は `types.mbt` 8,233、`operations.mbt` 154、`generated_test.mbt` 274、`pkg.generated.mbti` 1,799、`moon.pkg` 8。全 struct の constructor と `InputItem` の型生成を含み、15,000 行の監視閾値を下回る。

`moon clean` の直後に実行した `moon -C openai check --target wasm-gc` は **0.31 秒** (`/usr/bin/time` の wall time、28 tasks)。

## fix.yaml の効果(2026-09-22)

`openai/overlays/fix.yaml` は spec 自身が矛盾している箇所だけを直す(各 action に根拠)。census は `--overlay` で適用後の数字も出せる:

| | diagnostics |
|---|---:|
| OpenAI all ops、上流のまま | 30 |
| OpenAI all ops、fix.yaml 適用後 | 24 |

直したもの: Realtime*Session* の `modalities` に欠けていた `type: array`(4 箇所、JSONPath のフィルタで一括)、Transcript*Event の `logprobs.items.bytes` に欠けていた `items: {type: integer}`(2 箇所、`ChatCompletionTokenLogprob.bytes` と説明文が根拠)。`Tool` の discriminator と `WebSearchPreviewTool.type` の食い違い(mapping なし・値が 2 個の enum)は spec の意図が判然としないので直していない。上流が直せば apply_overlay.py が no-op を検出して落ちるので、そのとき action を消す。
