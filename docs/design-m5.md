# 設計メモ — M5: 2 本目の SDK `gaato/anthropic` と実 API テスト

目的は 2 つ。(1) `gaato/http` + `gaato/sdk-runtime` が 1 本目(OpenAI)に合わせすぎていないかを、形の違う 2 本目で確かめる。(2) 実際の API に対して `gaato/openai` と `gaato/anthropic` を動かす。

実 API の相手は OpenRouter(`https://openrouter.ai/api/v1`)を主にする: Responses API 互換の `/responses` と Anthropic Messages 互換の `/messages`(SSE も Anthropic のイベント形式)を持ち、`:free` モデルなら課金されない(キーの limit は 0)。OpenAI 本家は `OPENAI_API_KEY` があるときだけ、最小のリクエストで確認する。Anthropic 本家はキーが無いので今回は対象外(同じテストを `base_url` を変えて回せる形にしておく)。

## `gaato/anthropic` の公開 API(契約)

配置は `anthropic/`(module `gaato/anthropic`、依存は `gaato/http` と `gaato/sdk-runtime` だけ)。

```moonbit
pub struct Anthropic
pub fn Anthropic::new(
  api_key~ : String, transport : &@http.Transport, clock : &@clock.Clock,
  base_url? : String = "https://api.anthropic.com/v1", version? : String = "2023-06-01",
  auth_header? : AuthHeader = XApiKey, retry? : @runtime.RetryPolicy,
) -> Anthropic
pub(all) enum AuthHeader { XApiKey; Bearer }        // 本家は x-api-key、OpenRouter は Authorization: Bearer(x-api-key も受ける)
pub fn Anthropic::from_client(@runtime.Client, version? : String = "2023-06-01") -> Anthropic

pub(all) struct ApiErrorBody { type_ : String; message : String } derive(Eq, Debug)
pub fn api_error(@runtime.SdkError) -> ApiErrorBody?         // 本文が {"type":"error","error":{...}} なら取り出す

pub(all) enum Role { User; Assistant } derive(Eq, Debug)
pub(all) enum InputContent { Text(String); Blocks(Array[Json]) } derive(Eq, Debug)   // 文字列か、生のブロック配列(画像・tool_result などは生 JSON で逃がす)
pub(all) struct Message { role : Role; content : InputContent } derive(Eq, Debug)
pub fn Message::user(String) -> Message
pub fn Message::assistant(String) -> Message
pub(all) struct MessageRequest {
  model : String; max_tokens : Int; messages : Array[Message]
  system : String?; temperature : Double?; stop_sequences : Array[String]?
  extra : Map[String, Json]     // 既知キー(model max_tokens messages system temperature stop_sequences stream)と衝突したら Config
} derive(Eq, Debug)
pub fn MessageRequest::new(model~ : String, max_tokens~ : Int, messages~ : Array[Message], system? : String, temperature? : Double, stop_sequences? : Array[String], extra? : Map[String, Json]) -> MessageRequest

pub(all) enum ContentBlock {
  Text(String)
  Thinking(String)                 // {"type":"thinking","thinking":...}
  ToolUse(id~ : String, name~ : String, input~ : Json)
  Other(String, Json)              // 未知の type はそのまま通す
} derive(Eq, Debug)
pub(all) enum StopReason { EndTurn; MaxTokens; StopSequence; ToolUse; Refusal; Unknown(String) } derive(Eq, Debug)
pub(all) struct Usage { input_tokens : Int; output_tokens : Int } derive(Eq, Debug)
pub(all) struct MessageResponse { id : String; model : String; role : Role; content : Array[ContentBlock]; stop_reason : StopReason?; usage : Usage; raw : Json } derive(Eq, Debug)
pub fn MessageResponse::text(Self) -> String            // Text ブロックを順に連結
pub async fn Anthropic::create_message(Self, MessageRequest) -> MessageResponse raise @runtime.SdkError

pub(all) enum MessageEvent {
  MessageStart(MessageResponse)                              // content は空
  ContentBlockStart(index~ : Int, block~ : ContentBlock)
  TextDelta(index~ : Int, text~ : String)                    // content_block_delta / text_delta
  ThinkingDelta(index~ : Int, thinking~ : String)            // thinking_delta
  InputJsonDelta(index~ : Int, partial_json~ : String)       // input_json_delta
  ContentBlockStop(index~ : Int)
  MessageDelta(stop_reason~ : StopReason?, output_tokens~ : Int?)
  MessageStop
  Ping
  Error(ApiErrorBody)
  Other(String, Json)
} derive(Eq, Debug)
pub async fn[E : Error] Anthropic::stream_message(Self, MessageRequest, async (MessageEvent) -> Unit raise E) -> Unit
```

規則:
- ヘッダ: `anthropic-version: <version>`、`content-type: application/json`。認証は `AuthHeader` で `x-api-key: <key>` か `authorization: Bearer <key>`。ストリームは `accept: text/event-stream` と本文 `"stream": true`。Debug にキーを出さない。
- バケットは `"messages"`。
- SSE は `data` の JSON の `type` で分岐する(`event:` 行は `data.type` と食い違っても `data.type` を信じる)。`data` が JSON でなければ `Decode`。`message_stop` の後にストリームが続いても読み切って close する。
- `MessageResponse.raw` は応答全体。`usage` の未知フィールド(OpenRouter が `cost` などを足す)は無視。`stop_reason` が null なら `None`。
- `InputContent::Blocks` の JSON はそのまま `content` に置く(検証しない)。

## 実 API テスト(`runtime-tests/src/live/`、native、opt-in: `scripts/live.sh`)

環境変数 `OPENAI_API_KEY` / `OPENROUTER_API_KEY` を `@env.get_env_var` で読む。無い、または空なら、そのプロバイダのテストは `println("skip: ...")` して成功扱い。各テストは 60 秒の期限で包む。モデルは失敗時に次候補へ切り替える(`:free` は上流の共有プールで 429 になることがある。`RetryPolicy` は 429 を再試行するが、それでも失敗したら次のモデル)。候補: `nvidia/nemotron-3.5-lightning:free`、`liquid/lfm-2.5-2.6b:free`、`qwen/qwen3.8-27b:free`。

- OpenRouter × `gaato/openai`(`OpenAI::from_client` で `base_url=https://openrouter.ai/api/v1`、`Auth::Bearer`): `list_models` が 100 件以上返る、`create_response`(`max_output_tokens=64`)が `Completed` で `output_text` が空でない(`reasoning` 出力を含む応答でも)、`stream_response` で `OutputTextDelta` が 1 回以上来て `Completed` で終わる(未知イベントは `Other` で通る)。
- OpenRouter × `gaato/anthropic`(`AuthHeader::Bearer`、`base_url=https://openrouter.ai/api/v1`): `create_message`(`max_tokens=64`)が `role=Assistant`、`content` に 1 つ以上のブロック、`usage.output_tokens > 0`; `stream_message` で `MessageStart` → 何らかの delta → `MessageStop` の順序。`Thinking` ブロックや `thinking_delta` が来ても落ちない。
- OpenAI 本家(`OPENAI_API_KEY` があるとき、課金最小): `list_models`、`retrieve_model("gpt-5.4-mini")`(存在しなければ一覧の先頭)、`create_embeddings`(`text-embedding-3-small`、入力 1 件、`dimensions=64`)、`create_response`(`gpt-5.4-mini`、`max_output_tokens=16`)、`stream_response`(同)。合計 5 リクエスト。
- 実 API テストの失敗は SDK のバグとは限らない(上流の混雑)。失敗時のメッセージにプロバイダ・モデル・`api_error` の中身を含める。

## テスト(オフライン、`runtime-tests/src/anthropic/` と `anthropic/src/*_test.mbt`)
M3 と同じ: `FakeTransport` で要求の完全一致、fixture(本家ドキュメントの例と、OpenRouter の実応答の形の両方)からのデコード、未知ブロック型・未知 stop_reason・未知イベントが落ちないこと、`extra` の衝突、Debug にキーが出ないこと、ストリームのイベント列(チャンク境界を任意に割る)、コールバックのエラーで close。
