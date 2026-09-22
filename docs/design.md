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
pub(open) trait BodyStream { async fn read_some(Self) -> Bytes? raise HttpError; fn close(Self) -> Unit }
pub(open) trait Transport {
  async fn send(Self, Request) -> Response raise HttpError
  async fn send_stream(Self, Request) -> (ResponseHead, &BodyStream) raise HttpError
}
pub(all) suberror HttpError { Connect(String); Timeout(Int); Protocol(String) }
pub type Middleware = async (Request, async (Request) -> Response raise HttpError) -> Response raise HttpError
```
- `Request` / `Response` / `ResponseHead` は `Eq` と `Debug` を持つ(mock の照合とテストの失敗表示に使う)。
- `gaato/http` は依存ゼロなので `async test` を実行できない。async な挙動(`send_with` の順序、`each_event`、`FakeTransport`)の実行テストは `http-async` 側のテストに置く。`http` 側は純粋関数のテストとコンパイル確認まで。
- `BodyStream::read_some` が上げるのは `HttpError` だけ(2c で締めた)。ストリーム途中の切断は `Protocol`、タイムアウトは `Timeout`。
- キャンセルは `HttpError` にしない。`moonbitlang/async` のキャンセルは `Error` とは別のシグナルで `catch` では捕まらず、エラーに変換するとタスクグループが「失敗」として扱ってしまう。transport はシグナルをそのまま伝播させ、後始末は `defer` / `errdefer` で行う。`Cancelled` は 2c で契約から外した。
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

SSE の判断:
- `retry` は空でない ASCII 数字列かつ `Int` に収まる場合だけ受理する。空・非数字・オーバーフローは無視し、それ以前の有効な値を保持する。
- `SseEvent.retry` は前回のイベント送出以降に受理した最後の値。データのない空行では保持し、次のイベントに載せてから `None` に戻す。last-event-id のようには永続化しない。
- 未設定の id は `None`、明示的な空 id は `Some("")`。`data:` が一行ある空文字イベントは送出するが、data 行のないブロックは送出しない。
- `finish()` は未完イベントを捨てて終端状態にする。繰り返し呼び出しと、その後の `feed()` は `[]` を返す。
- `each_event` の実装は callback の型を `raise E` に保ち、関数の戻り側は `raise` (`Error`) とする。`BodyStream::read_some()` が任意の `Error` を送出するため、`raise E` だけには限定できない。読み取り・callback のエラーはそのまま伝播し、`defer` で必ず close する。

`gaato/http/mock`: `FakeTransport::new()`、`.expect(method, url_suffix, Response)`、`.expect_stream(..., chunks : Array[Bytes])`、`.sent() -> Array[Request]`、`.assert_complete()`。不一致はその場で raise し、かつラッチして `assert_complete` でも落とす。

`gaato/http-async`: `AsyncTransport::new(timeout_ms? = 30000)`。`impl Transport`。`@http.Client` を直接使い、`content-length` は async 側に任せる、応答ヘッダ名を小文字化、`send_stream` は `read_some` をそのまま `BodyStream` にする、`@async.with_timeout` でタイムアウト、キャンセル時はシグナルを伝播させつつ `defer` で接続を close。接続プールは M1 では持たなかった(1 リクエスト 1 接続)。2026-09-22 に keep-alive プールを追加: `AsyncTransport::new(max_idle_per_origin? = 4, idle_max_ms? = 10000)`。本文を最後まで読み `Connection: close` でない接続だけ origin ごとに保管し、同時実行は制限しない(空きが無ければ dial する)。再利用した接続が応答ヘッダ前に失敗したら、冪等メソッドか `Idempotency-Key` 付きの要求だけ新規接続で 1 回再送し、それ以外は失敗を返す(Go の net/http と同じ規則)。`AsyncTransport::close()` で保管中の接続を閉じる。移植元は discord.mbt の `internal/pool`。

http-async の判断:
- タイムアウトは `@async.with_timeout(ms, f, error=HttpError::Timeout(ms))` で掛ける。`timeout_ms <= 0` は接続せずに即 `Timeout`。`send` は接続から本文の読み切りまでを 1 つの期限で、`send_stream` は応答ヘッダまでを 1 つの期限で、その後は `read_some` 1 回ごとに新しい期限(アイドルタイムアウト)で縛る。
- キャンセルには何もしない。`catch` に現れないのでそのまま伝播し、接続は `defer` / `errdefer` で閉じる。テストで、外側のキャンセルが `catch` を素通りすることと、サーバ側から接続の close が見えることを確認している。
- エラーの写し方: URL の形式不正・未対応スキーム・未知のメソッドは接続前に `Protocol`。native は `Client` の生成時に DNS/TCP/TLS を済ませるので、生成時の失敗が `Connect`、それ以降の失敗が `Protocol`。js は fetch が遅延接続なので、応答ヘッダまでの失敗を `Connect` とする(fetch は接続失敗と不正応答を区別して返さない)。本文読み取り中の失敗は両ターゲットとも `Protocol`。
- 送信ヘッダ: async の `Headers` は Map なので、同名の複数値は `", "` で連結する。呼び出し側の `content-length` は送らず async に計算させる。
- 応答ヘッダ: 名前は小文字化。async は `Set-Cookie` を `cookies` に分離して持つので、属性から `set-cookie` 値を組み立て直して複数値として載せる(元の文字列とバイト単位で一致する保証はない)。それ以外の同名ヘッダは async が渡す形のまま。
- リダイレクト: native は追従せず 3xx をそのまま返す(テストで確認)。js は fetch の既定動作(追従)になる。js での統一は M2 以降の課題。
- URL: `http` / `https` の絶対 URL のみ。フラグメントは送らない。
- loopback テストは `http-async/src/loopback`(native 限定パッケージ)に置き、`127.0.0.1:0` のエフェメラルポートを使う。全テストを 5 秒の期限で包む。ソケットを使わない async テスト(middleware の順序、`FakeTransport`、`each_event`、検証エラー)は js でも実行される。

M1 の既知の制限:
- リクエスト本文は `Bytes` で全量バッファする(ストリーミング送信なし)。discord.mbt は multipart のパートを接続へ逐次書き込んでいるので、大きなファイル送信を移すなら `Transport` にストリーミング送信を足す必要がある。
- SSE パーサに行長の上限なし。(接続プールは 2026-09-22 に追加済み。)

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
