# 設計メモ — M6: tool calling・互換サーバの実 API テスト・CI

背景(2026-09-22 の他言語 SDK 調査): 「OpenAI 互換」SDK がほぼ全員実装しているのは chat/completions + SSE + tool calling + base_url。`gaato/openai` に足りないのは tool calling の公開 API。Anthropic 側も tool_use は Messages API の中核。互換サーバはローカルに用意済み(Ollama、LiteLLM の `/v1/messages`、vLLM の `/v1/messages`)。

## 1. tool calling(公開 API の追加)

### `gaato/openai`
```moonbit
pub(all) struct ToolDef { name : String; description : String?; parameters : Json; strict : Bool? } derive(Eq, Debug)   // parameters は JSON Schema
pub fn ToolDef::new(name~, parameters~, description?, strict?) -> ToolDef
pub(all) struct ToolCall { id : String; name : String; arguments : String } derive(Eq, Debug)   // arguments は生の JSON 文字列(不正でも落とさない)
pub fn ToolCall::arguments_json(Self) -> Json raise @json.ParseError
// ChatRequest / ResponseRequest に `tools : Array[ToolDef]?` と `tool_choice : Json?` を追加(::new にラベル付き任意引数)
// ChatMessage に `tool_calls : Array[ToolCall]?` と `tool_call_id : String?` を追加。`ChatMessage::tool(tool_call_id~, content~)` と `ChatMessage::assistant_tool_calls(Array[ToolCall])` を追加。M4f で `tool` role が `name` を `tool_call_id` として流用していたのを廃止し、`tool` role は `tool_call_id` を要求する(未 publish なので互換性の配慮は不要)
// ChatCompletion に `tool_calls : Array[ToolCall]`(無ければ空)を追加
// ChatEvent に `ToolCallDelta(index~ : Int, id~ : String?, name~ : String?, arguments~ : String)` を追加(chunk の tool_calls[].function.arguments の断片。集約は利用者側だが、`ToolCallAccumulator` を提供する)
pub struct ToolCallAccumulator;  ::new();  fn feed(Self, index~, id?, name?, arguments~) -> Unit;  fn finish(Self) -> Array[ToolCall]
// Response 側: Response に `tool_calls : Array[ToolCall]`(output の function_call アイテム: call_id / name / arguments)、ResponseEvent に `FunctionCallArgumentsDelta(item_id~, delta~)` と `FunctionCallArgumentsDone(item_id~, arguments~)`、ResponseRequest の input に function_call_output を渡せる `ResponseRequest::with_tool_outputs(Self, Array[(call_id, output)])`
```
### `gaato/anthropic`
```moonbit
pub(all) struct ToolDef { name : String; description : String?; input_schema : Json } derive(Eq, Debug)
// MessageRequest に `tools : Array[ToolDef]?` と `tool_choice : Json?`。ContentBlock::ToolUse は既存。
// 入力側: `Message::tool_result(tool_use_id~, content~ : String, is_error? : Bool)`(InputContent::Blocks で tool_result ブロックを組む)と `Message::assistant_blocks(Array[Json])`
// ストリーム: 既存の InputJsonDelta を集約する `ToolUseAccumulator`(content_block_start の ToolUse で開始、InputJsonDelta を連結、ContentBlockStop で `ToolUse` を確定)
```
- 既存の公開 API は壊さない(追加のみ。`::new` の任意引数追加は互換)。
- 極小モデルは tool_call をまともに出せないので、実 API では「tools を渡しても 4xx にならず、応答がデコードできる」だけを確認し、tool_call の往復(assistant の tool_calls → tool メッセージ → 続き)はオフラインの fixture で担保する。fixture は OpenAI 公式ドキュメントの例と、Ollama / LiteLLM の実応答の形の両方。

## 2. 互換サーバ向けの実 API テスト(`runtime-tests/src/live/`)
- `ANTHROPIC_COMPAT_BASE_URL` / `ANTHROPIC_COMPAT_MODEL` / `ANTHROPIC_COMPAT_API_KEY`(任意)があるとき、`gaato/anthropic` を `AuthHeader::XApiKey` でそのサーバに向けて `create_message` と `stream_message` を確認する(M5 の OpenRouter 版と同じ assert)。`thinking` ブロックが来ても落ちないこと(vLLM は `signature` を付ける)。
- M4f の `OPENAI_COMPAT_*` テストに tools を渡す 1 ケースを足す。
- モデルは thinking なしで tools パラメータを受け付ける小型モデル(`qwen2.5:0.5b`)を使用する。`smollm2:135m` は tools を渡すと 400 になるため対象外。`max_tokens` は 64。

## 3. CI(済み、M6 の前にコミット)
`scripts/compat-servers.sh`(Ollama + LiteLLM の `/v1/messages`、`*_COMPAT_*` を出力)、`scripts/litellm.yaml`、`.github/workflows/live-compat.yml`。`MBT_SDK_ENV=/dev/null scripts/live.sh` で env ファイルを読まずに動くことをローカルで確認済み(4/4)。Ollama / LiteLLM は固定しない(常に最新): 互換サーバの版上げで落ちるのはこの基盤が検知したいドリフトで、live-compat はゲートではないため。

## M6 の判断

- `ChatMessage.content` は既存の `String` のままにした。`assistant_tool_calls` で `content` を省略した場合は内部では空文字を保持し、tool call があり空文字の assistant message だけ wire の `content` を省略する。これにより既存 field の型を壊さず、生成型が許す tool-call-only assistant message を送れる。
- chat request は message、tool、tool choice をいったん生成型へ decode してから再 encode する。生成 `ChatCompletionRequestToolMessage` だけは upstream schema 上の任意 `name` field を持たないため、生成型の検証と再 encode の後に tool role の `name` を補う。この生成型の差は隠さず、コードコメントと最終報告にも残す。
- `ResponseRequest` は既存の公開 `input : String` を維持し、`with_tool_outputs` 用の private な tool output 列を追加した。tool output があるときは元の文字列を user の `EasyInputMessage` にし、その後へ呼び出し順の `FunctionCallOutputItemParam` を追加して、すべて生成型で encode する。`with_tool_outputs` の複数回呼び出しは末尾へ累積する。
- `ToolCallAccumulator` は index ごとに最初に届いた id / name を保持し、arguments を到着順に連結する。`finish` は index 順で、欠けた id / name は空文字にする。stream delta 自体を失わず公開することを優先し、途中の不完全な互換応答で accumulator だけが例外を増やさない。
- Anthropic の `ToolUseAccumulator` は `content_block_stop` を受けた tool use だけを index 順に返す。`feed` は partial JSON を生文字列として連結して例外を出さず、`finish` で JSON parse error を返す。`content_block_start` の空 `input` は初期値に使わず、stream の `input_json_delta` を正とした。
- Anthropic 互換 live test は key があれば既定の `XApiKey`、無ければ `Client` の `NoAuth` を使う。buffered / stream とも `max_tokens=64`、既存の timeout / retry を使い、thinking の有無や tool call の発生は要求しない。

## 引き継ぎ時の検証 (2026-09-22)

`scripts/gates.sh` は wasm-gc 129 / JS 169 / native 201 テスト、generator 47 テスト、生成物・整形・公開API・census の全チェックを通過した。

Ollama に導入済みの `qwen2.5:0.5b` で tools パラメータ付き Chat Completions を確認し、更新した `scripts/litellm.yaml` も一時的な別ポートの LiteLLM で検証した。`scripts/live.sh` のローカル2ケースは成功、外部 OpenAI / OpenRouter の3ケースは鍵を渡さずスキップ。外部APIと vLLM はこの引き継ぎでは未検証。Ollama / LiteLLM のバージョンは引き続き固定しない。
