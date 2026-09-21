# 設計メモ — M1: sans-IO HTTP 層

## 調査で確定した前提

- `moonbitlang/async@0.22.1` の `@http.Client` は **native / js / wasm で同一 API**(js は中身が fetch、`read_some` / `read_until` でストリーム読みも可)。ただし自由関数 `get` / `post` / `*_stream` は native+wasm 限定 → **`Client` を直接使う**。→ transport アダプタは 1 モジュールで足りる(`http-native` / `http-js` に割らない)。
- MoonBit の import はモジュール単位。`moonbitlang/async` に依存するものは core と別モジュールにする(slack-mb の規則)。`async fn` を持つ trait 自体は依存ゼロのモジュールに置ける(slack-mb `slack/api/transport.mbt:74` が実例)。
- この機械にも mooncakes にも、**増分 SSE パーサの実装は無い**(mizchi/llm は curl の出力を後から行分割、llm-mb はバッファして一括 parse)。WHATWG の仕様から書く。
- discord.mbt の HTTP 層はボディが `Json` 固定。流用するのは設計(middleware 型、`Paginator[T]`、`RateLimiter` trait、モック transport の「FIFO 照合+違反ラッチ」`src/testkit/harness.mbt:197-225`)で、コードのコピーではない。

## リポジトリ構成(M1)

場所: `~/ghq/github.com/gaato/mbt-sdk`(ローカルのみ。`git init` + `jj git init --colocate`。**GitHub リポジトリ作成・push・mooncakes publish は M1 ではしない**。名前は publish まで仮)

```
mbt-sdk/
  moon.work                 members = ["http", "http-async"]
  AGENTS.md                 規約(下記)
  docs/design.md            この計画の設計部分
  http/                     module gaato/http — 依存ゼロ、全ターゲット
    moon.mod                import なし、preferred_target = "wasm-gc"
    src/                    Request / Response / Headers / Transport / BodyStream / HttpError
    src/sse/                増分 SSE パーサ(純粋)
    src/mock/               FakeTransport(台本応答+記録+違反ラッチ)
  http-async/               module gaato/http-async — moonbitlang/async@0.22.1
    moon.mod                supported: native + js
    src/                    AsyncTransport(@http.Client を直接使用)
```

mock と sse を `http` モジュール内のパッケージにするのは、依存がゼロで割る理由が無いから(モジュール = publish 単位 = リリースの手間)。

## 公開 API(契約)

`gaato/http`:
```moonbit
pub(all) struct Request { http_method : String; url : String; headers : Headers; body : Bytes }
pub(all) struct Response { status : Int; headers : Headers; body : Bytes }
pub(all) struct ResponseHead { status : Int; headers : Headers }
// Headers: 名前は小文字に正規化、同名複数値を保持(set / append / get / get_all / iter)
pub(open) trait BodyStream { async fn read_some(Self) -> Bytes?; fn close(Self) -> Unit }
pub(open) trait Transport {
  async fn send(Self, Request) -> Response raise HttpError
  async fn send_stream(Self, Request) -> (ResponseHead, &BodyStream) raise HttpError
}
pub(all) suberror HttpError { Connect(String); Timeout(Int); Protocol(String); Cancelled }
pub type Middleware = async (Request, async (Request) -> Response raise HttpError) -> Response raise HttpError
```
- transport は status を解釈しない(4xx/5xx も `Response` で返す。分類は M2 の runtime の仕事)。
- `Response::text()` / `json()`、`Request` の builder(`Request::get(url)`, `.header(k, v)`, `.json_body(j)`)を付ける。

`gaato/http/sse`:
```moonbit
pub(all) struct SseEvent { event : String; data : String; id : String?; retry : Int? }
pub struct SseParser
pub fn SseParser::new() -> SseParser
pub fn SseParser::feed(Self, Bytes) -> Array[SseEvent]   // チャンク境界は任意
pub fn SseParser::finish(Self) -> Array[SseEvent]        // 仕様どおり、未ディスパッチの末尾は捨てる
pub async fn each_event(&BodyStream, async (SseEvent) -> Unit raise E) -> Unit raise E  // 便利関数
```
WHATWG「Server-sent events」の解釈規則に準拠: `\n` / `\r\n` / `\r`、先頭 BOM、コメント行、複数 `data:` の改行連結、`id` に NUL を含む場合は無視、`retry` は数字のみ、UTF-8 の多バイト文字がチャンク境界で割れても壊れない(バイトで溜めて行単位でデコード)。`[DONE]` の扱いは API 固有なので入れない。

`gaato/http/mock`: `FakeTransport::new()`、`.expect(method, url_suffix, Response)`、`.expect_stream(..., chunks : Array[Bytes])`、`.sent() -> Array[Request]`、`.assert_complete()`。不一致はその場で raise し、かつラッチして `assert_complete` でも落とす。

`gaato/http-async`: `AsyncTransport::new(timeout_ms? = 30000)`。`impl Transport`。`@http.Client` を直接使い、`content-length` は async 側に任せる、応答ヘッダ名を小文字化、`send_stream` は `read_some` をそのまま `BodyStream` にする、`@async.with_timeout` でタイムアウト、キャンセル時は接続を close。接続プールは M1 では持たない(1 リクエスト 1 接続)。

## 検証

```fish
cd ~/ghq/github.com/gaato/mbt-sdk
moon -C http check --deny-warn --target wasm-gc; and moon -C http check --deny-warn --target native; and moon -C http check --deny-warn --target js
moon -C http test --target wasm-gc; and moon -C http test --target native; and moon -C http test --target js
moon -C http-async check --deny-warn --target native; and moon -C http-async check --deny-warn --target js
moon -C http-async test --target native
moon fmt --check; and moon info; and jj diff --stat '**/*.mbti'   # mbti 差分なし
```
- SSE: WHATWG 仕様の例をすべてテストにする。加えて「同じ入力を全バイト位置で 2 分割しても結果が同じ」ことを総当たりで確認(多バイト文字・`\r\n` の分割を含む)。
- http-async: loopback サーバで、通常応答・4xx をそのまま返すこと・チャンク分割された SSE をストリームで読めること・タイムアウトで `Timeout` が上がることを確認。js は `check` のみ(実行テストは M2 で node の test runner を入れてから)。
- 最後に私が、今日生成した oas2moon の runtime と discord.mbt の `HttpTransport` の両方をこの `Transport` で表現できるか机上で確認し、無理があれば M2 の前に API を直す。

## M2 以降(今回は実装しない)

- **M2 `sdk-runtime`**: `Retry-After` 尊重のリトライ、エラー分類、`Paginator[T]` と `RateLimiter` の一般化、`Presence[T]` / `ObjBuilder`、open enum(`Unknown(String)`)ヘルパ、multipart(`Yoorkin/multipart` を評価)、webhook 署名検証。sleep が要るので `moonbitlang/async` 依存にするか時計を注入するかはここで決める。
- **M3 最初の利用者**: OpenAI の薄い手書きスライス(responses の作成とストリーム、models 一覧)。vendoring した spec、`overlays/fix.yaml` と `overlays/moonbit.yaml`、カセット方式のテスト。
- **M4 生成と自動化**: 正規化は既存の OpenAPI ツール+MoonBit の出力部、stable / nightly(moonbit-docker)の二系統 CI、spec 差分 → 再生成 → テスト → publish を bot が完走。GitHub リポジトリ作成と publish はこの段階で確認を取ってから。
