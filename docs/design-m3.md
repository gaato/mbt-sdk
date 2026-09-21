# 設計メモ — M3: 最初の利用者 `gaato/openai`(薄い手書きスライス)

目的は OpenAI SDK を完成させることではなく、`gaato/http` + `gaato/sdk-runtime` が実際の API で使えるかを確かめること。範囲は models / embeddings / responses(通常とストリーム)だけ。ここで手書きした型と操作は、M4 のジェネレータの出力と突き合わせる正解データにもなる。

## 配置

```
openai/                    module gaato/openai — 依存は gaato/http と gaato/sdk-runtime だけ(async runtime なし)
  moon.mod
  src/                     OpenAI クライアントと型
  spec/openai.yaml         vendoring した上流 spec(openai/openai-openapi の manual_spec ブランチ)
  spec/SOURCE.md           取得元 URL・取得日・sha256
  overlays/fix.yaml        ① 上流の誤りの修正(言語非依存。各 action に根拠を書く)
  overlays/moonbit.yaml    ② MoonBit 向けの注釈(x-moonbit-*)
tools/apply_overlay.py     OpenAPI Overlay 1.x の適用(RFC 9535 JSONPath)。ゼロ件マッチと no-op の action をエラーにする
runtime-tests/src/openai/  実行テスト(FakeTransport / FakeClock。ソケットなし)
```

## 公開 API(契約)— `gaato/openai`

```moonbit
pub struct OpenAI
pub fn OpenAI::new(
  api_key~ : String, transport : &@http.Transport, clock : &@clock.Clock,
  base_url? : String = "https://api.openai.com/v1",
  organization? : String, project? : String, retry? : @runtime.RetryPolicy,
) -> OpenAI
pub fn OpenAI::from_client(@runtime.Client) -> OpenAI      // 認証や base_url を自分で組んだ Client を使う(Azure・互換 API・テスト用)

pub(all) struct ApiErrorBody { message : String; type_ : String?; param : String?; code : String? } derive(Eq, Debug)
pub fn api_error(@runtime.SdkError) -> ApiErrorBody?       // Status / RateLimited の本文が {"error": {...}} なら取り出す

pub(all) struct Model { id : String; created : Int64?; owned_by : String? } derive(Eq, Debug)
pub async fn OpenAI::list_models(Self) -> Array[Model] raise @runtime.SdkError
pub async fn OpenAI::retrieve_model(Self, String) -> Model raise @runtime.SdkError

pub(all) struct Usage { input_tokens : Int; output_tokens : Int; total_tokens : Int } derive(Eq, Debug)
pub(all) struct EmbeddingRequest { model : String; input : Array[String]; dimensions : Int?; user : String? } derive(Eq, Debug)
pub fn EmbeddingRequest::new(model~ : String, input~ : Array[String], dimensions? : Int, user? : String) -> EmbeddingRequest
pub(all) struct Embedding { index : Int; embedding : Array[Double] } derive(Eq, Debug)
pub(all) struct EmbeddingResponse { data : Array[Embedding]; model : String; prompt_tokens : Int; total_tokens : Int } derive(Eq, Debug)
pub async fn OpenAI::create_embeddings(Self, EmbeddingRequest) -> EmbeddingResponse raise @runtime.SdkError

pub(all) enum ResponseStatus { Completed; Failed; InProgress; Incomplete; Cancelled; Queued; Unknown(String) } derive(Eq, Debug)
pub(all) struct ResponseRequest {
  model : String; input : String; instructions : String?
  max_output_tokens : Int?; temperature : Double?; previous_response_id : String?
  extra : Map[String, Json]          // ここに無いパラメータの逃げ道。既知キーと衝突したら Config エラー
} derive(Eq, Debug)
pub fn ResponseRequest::new(model~ : String, input~ : String, instructions? : String, max_output_tokens? : Int, temperature? : Double, previous_response_id? : String, extra? : Map[String, Json]) -> ResponseRequest
pub(all) struct Response { id : String; status : ResponseStatus; model : String; output_text : String; usage : Usage?; raw : Json } derive(Eq, Debug)
pub async fn OpenAI::create_response(Self, ResponseRequest) -> Response raise @runtime.SdkError

pub(all) enum ResponseEvent {
  Created(Response); InProgress(Response); OutputTextDelta(String); OutputTextDone(String)
  Completed(Response); Failed(Response); Incomplete(Response)
  Error(ApiErrorBody); Other(String, Json)            // 未知のイベント型は (type, 生の JSON) で必ず通す
} derive(Eq, Debug)
pub async fn[E : Error] OpenAI::stream_response(Self, ResponseRequest, async (ResponseEvent) -> Unit raise E) -> Unit   // raise の形は sse.each_event と同じ扱い
```

規則:
- ヘッダ: `authorization: Bearer <key>`、`openai-organization` / `openai-project`(指定時のみ)、JSON 本文には `content-type: application/json`。ストリーム要求は `accept: text/event-stream` と本文の `"stream": true`。`OpenAI` と関連型の Debug に API キーを出さない。
- バケット(rate limit 用)は操作ごとに `"models"` / `"embeddings"` / `"responses"`。
- デコードは `@json` パッケージ(`gaato/sdk-runtime/json`)の `field` / `opt_field` / `open_string` を使って手書きする。未知のフィールドは無視。必須フィールドが無ければ `SdkError::Decode`(本文つき)。
- `Model.created` は JSON の数値から `Int64` に読む(2038 年以降も壊れないように `Int` にしない)。
- `Response.output_text` は `output[]` のうち `type == "message"` の `content[]` で `type == "output_text"` の `text` を順に連結したもの。無ければ `""`。`raw` は応答全体。
- `Usage` は responses の `usage.input_tokens / output_tokens / total_tokens`。embeddings の usage は `prompt_tokens` / `total_tokens` を `EmbeddingResponse` に平らに載せる。
- ストリーム: SSE の `data` を JSON として読み、その `type` で分岐する(`event:` 行は信用せず補助にだけ使う)。`response.created` / `response.in_progress` / `response.completed` / `response.failed` / `response.incomplete` は `response` フィールドを `Response` に、`response.output_text.delta` は `delta`、`response.output_text.done` は `text`、`error` は `ApiErrorBody`、それ以外は `Other`。`data: [DONE]` が来たら無視して終了扱い。JSON として不正な `data` は `SdkError::Decode`。コールバックのエラーはそのまま伝播し、どの経路でもストリームを close する。
- `ResponseRequest.extra` のキーが既知のキー(`model` `input` `instructions` `max_output_tokens` `temperature` `previous_response_id` `stream`)と衝突したら、送信せず `SdkError::Config`。

## overlay

- `overlays/fix.yaml`: 今回のスライスを書く過程で見つけた上流 spec の誤りだけを入れる。各 action の `description` に根拠(公式ドキュメントの URL か、spec 内の例との矛盾)を書く。見つからなければ actions は入れずに、その旨を `spec/SOURCE.md` に書く(空の actions が仕様上許されないなら、ファイル自体を作らない)。推測で修正を足さない。
- `overlays/moonbit.yaml`: `x-moonbit-include: true` を、このスライスが使う操作(`listModels` `retrieveModel` `createEmbedding` `createResponse`)に付ける。`Model.created` に `x-moonbit-type: Int64`。M4 のジェネレータが読む。
- `tools/apply_overlay.py` は `uv run tools/apply_overlay.py <spec> <out> <overlay>...` で動く。ゼロ件マッチの action と、適用しても文書が変わらない action をエラーにする(`x-allow-zero-match: true` で個別に許可)。生成物(overlay 適用後の spec)はコミットしない。

## テスト(`runtime-tests/src/openai/`、native と js)

`FakeTransport` の台本で: 各操作の要求(メソッド、URL、ヘッダ、JSON 本文の完全一致)、spec 内の例(`x-oaiMeta` の response 例)を元にした応答のデコード、未知フィールド・未知の status・未知のイベント型が落ちないこと、必須フィールド欠落が `Decode` になること、401 / 429 の本文から `api_error` が取れること、429 → 成功の再試行(FakeClock で sleep を確認)、ストリームのイベント列(チャンク境界を任意に割る)、`[DONE]`、コールバックのエラーで close されること、`extra` の衝突、Debug にキーが出ないこと。
