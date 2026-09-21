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

## M3 の判断

- `OpenAI` は `@runtime.Client` だけを保持し、手書きの `Debug` は runtime の内部を一切たどらず `OpenAI(<credentials redacted>)` だけを返す。API key は `@runtime.Auth::Bearer` に渡し、organization / project は default headers として設定する。
- `EmbeddingRequest::new` は `input`、`ResponseRequest::new` は `extra` を copy する。constructor 呼び出し後の caller 側の変更が、後の送信内容を変えないようにした。
- `retrieve_model` の path parameter は spec の model ID をそのまま `/models/` の後ろへ置く。今回の spec の ID は colon を含み得るが slash を含まず、契約には percent-encoding の規則や公開 helper がないため、追加の変換はしない。
- core JSON の `Int64` decoder は JSON string を期待し、JSON number を受理しなかった。このため `Model.created` は `Json::Number` を直接読み、通常の符号付き十進整数表記は文字列表現で Int64 全域を厳密に範囲検査し、それ以外の数値表現は Double 値の整数性と範囲を検査する。`2147483648` を回帰テストにした。
- 必須として decode するのは、公開値を構成するために必要な field と spec 上の配列要素の discriminator である。`Model.created` / `owned_by` は vendored spec では required だが、M3 契約の型が optional なので契約を優先する。`Response` は `id` / `status` / `model` / `output` を必須、`usage` を missing / null のどちらでも `None` とした。
- vendored spec の `Response.status` enum は `completed` / `failed` / `in_progress` / `incomplete` だけだが、M3 契約に従って `cancelled` / `queued` も既知値とし、それ以外は `Unknown(raw)` に保持する。
- `Response.output_text` は top-level の SDK convenience field を信用せず、契約どおり `output` の message 順、各 message の content 順で `output_text.text` を連結する。対応する part が無いときは空文字にする。
- HTTP error の `api_error` は `Status` / `RateLimited` だけを対象にし、標準 envelope または field 型が不正なら `None` を返す。stream の `error` event は top-level の `type` が event discriminator なので `ApiErrorBody.type_ = None` とする。
- streaming は `@sse.each_event` に close の所有権を渡す。`[DONE]` は private な終了 error で callback から抜け、normal EOF / `[DONE]` / callback error / JSON decode error の全経路で `each_event` の `defer` が stream を close する。SSE の `event:` は分岐に使わず JSON の `type` だけを使う。
- `ResponseRequest.extra` は既知 key との衝突を body 構築の最初に全件検査する。buffered / streaming のどちらでも transport を呼ぶ前に `SdkError::Config` とし、衝突が無い extra は既知 field の後ろへ insertion order のまま追加する。
- operation bucket は list / retrieve が `models`、embedding が `embeddings`、buffered / streaming response が `responses`。テスト用 limiter で acquire / observe の両方を固定した。
- response fixture は vendored spec の `x-oaiMeta` examples を縮小して使い、embedding vector や response output は構造を保ったまま最小件数にした。未知 field、未知 event、未知 status も別途混ぜた。
- decode / body builder / event decoder は public API を増やさない private な同期関数にしたため、その直接テストだけは `decode_wbtest.mbt` に置く。公開 API の要求・retry・streaming は `runtime-tests/src/openai/openai_test.mbt` から black-box で検証する。
- 今回の slice では言語非依存の上流 spec error は見つからなかったため `overlays/fix.yaml` は作らない。MoonBit 固有 overlay は 4 operation の include と `Model.created` の Int64 注釈だけにした。
