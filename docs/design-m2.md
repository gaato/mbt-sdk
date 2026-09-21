# 設計メモ — M2: `gaato/sdk-runtime`

API に依存しないクライアント runtime。依存は `gaato/http` だけ。async runtime には依存しない:
時間(sleep と現在時刻)は `Clock` trait で注入する。実装は `gaato/http-async` に `AsyncClock` として置く。
こうすると retry と rate limit を偽の時計で決定的にテストでき、モジュールは全ターゲットで check できる。

分割: 3a(純粋な部分)→ 3b(`Clock`・retry・`RateLimiter`・`Paginator`・認証)→ 3c(multipart writer)。
webhook 署名検証は HMAC の依存が増えるので、このモジュールには入れない(後で別モジュール)。

## 3a の公開 API(契約)

### `gaato/sdk-runtime`(root パッケージ)

```moonbit
pub(all) suberror SdkError {
  Transport(@http.HttpError)                                             // 応答が得られなかった
  Status(status~ : Int, headers~ : @http.Headers, body~ : Bytes)          // 2xx 以外(429 を除く)
  RateLimited(retry_after_ms~ : Int?, headers~ : @http.Headers, body~ : Bytes)  // 429
  Decode(message~ : String, body~ : Bytes)                                // 2xx だが本文を解釈できない
  Config(String)                                                          // 呼び出し側の設定ミス
} derive(Debug)

pub fn classify(response : @http.Response, now_unix_ms? : Int64) -> @http.Response raise SdkError
pub fn SdkError::status(Self) -> Int?
pub fn SdkError::is_retryable(Self) -> Bool

pub fn parse_retry_after(value : String, now_unix_ms? : Int64) -> Int?
pub fn retry_after_ms(headers : @http.Headers, now_unix_ms? : Int64) -> Int?

pub(all) struct Backoff { base_ms : Int; max_ms : Int; factor : Double; jitter : Double } derive(Eq, Debug)
pub fn Backoff::default() -> Backoff                  // base 500, max 30000, factor 2.0, jitter 0.2
pub fn Backoff::delay_ms(Self, attempt : Int, random : Double) -> Int
```

規則:
- `classify`: 200–299 は応答をそのまま返す。429 は `RateLimited`(`retry_after_ms` は `retry_after_ms(headers, now_unix_ms?)` の結果)。それ以外は `Status`。3xx も `Status`(transport が追従しなかったリダイレクトは呼び出し側が扱う)。
- `is_retryable`: `Transport(Connect(_))`・`Transport(Timeout(_))`・`RateLimited`・`Status` のうち 408 / 409 / 500 / 502 / 503 / 504 が true。`Transport(Protocol(_))`・`Decode`・`Config`・その他の `Status` は false。
  (409 は OpenAI・Stainless 系 SDK がロック競合として再試行する慣行に合わせる。冪等でない要求を再試行してよいかの判断は 3b の retry 側で行う。ここは「状態としては再試行に値する」だけを答える。)
- `status`: `Status` と `RateLimited`(= 429)は `Some`、他は `None`。
- `parse_retry_after`: 戻り値はミリ秒。受理する形は (1) 非負の 10 進整数秒 (2) 非負の 10 進小数秒(`"1.5"` → 1500。小数点以下は 3 桁まで使い、残りは切り捨て)(3) `now_unix_ms` が与えられたときだけ HTTP-date(IMF-fixdate、例 `Sun, 06 Nov 1994 08:49:37 GMT`)。過去の日時は `Some(0)`。前後の空白は無視。`Int` に収まらない値は `Int` の最大値に丸める。解釈できなければ `None`。obsolete な日付形式(RFC 850、asctime)は受理しない。
- `retry_after_ms`: `retry-after-ms` ヘッダ(非負の 10 進整数または小数のミリ秒。OpenAI が送る)を先に見て、無いか解釈できなければ `retry-after` を `parse_retry_after` に渡す。
- `Backoff::delay_ms`: `attempt` は 0 始まり。`raw = min(max_ms, base_ms * factor^attempt)`(オーバーフローしないよう Double で計算して丸める)。`random` は [0, 1) の一様乱数を呼び出し側が渡す。結果は `raw * (1 - jitter + 2 * jitter * random)` を [0, max_ms] に収めた `Int`。`attempt < 0` は 0 として扱う。`random` が範囲外なら [0, 1) に切り詰める。乱数源そのものは持たない(純粋関数)。

### `gaato/sdk-runtime/json`

```moonbit
pub(all) enum Presence[T] { Absent; Null; Value(T) } derive(Eq, Debug)
pub fn[T] Presence::to_option(Self[T]) -> T?                 // Absent / Null → None
pub fn[T] Presence::from_option(T?) -> Presence[T]           // None → Absent
pub fn[T, U] Presence::map(Self[T], (T) -> U) -> Presence[U]
pub fn[T] Presence::is_absent(Self[T]) -> Bool

pub struct ObjBuilder
pub fn ObjBuilder::new() -> ObjBuilder
pub fn[T : ToJson] ObjBuilder::field(Self, String, T) -> Self            // 常に書く
pub fn[T : ToJson] ObjBuilder::opt(Self, String, T?) -> Self             // None は省略
pub fn[T : ToJson] ObjBuilder::presence(Self, String, Presence[T]) -> Self  // Absent は省略、Null は null
pub fn ObjBuilder::build(Self) -> Json

pub fn[T : @json.FromJson] field(obj : Map[String, Json], key : String, path : @json.JsonPath) -> T raise @json.JsonDecodeError
pub fn[T : @json.FromJson] opt_field(obj : Map[String, Json], key : String, path : @json.JsonPath) -> T? raise @json.JsonDecodeError
pub fn[T : @json.FromJson] presence_field(obj : Map[String, Json], key : String, path : @json.JsonPath) -> Presence[T] raise @json.JsonDecodeError
pub fn expect_object(json : Json, path : @json.JsonPath) -> Map[String, Json] raise @json.JsonDecodeError

pub fn[T] open_string(json : Json, path : @json.JsonPath, known : (String) -> T?, unknown : (String) -> T) -> T raise @json.JsonDecodeError
pub fn[T] open_int(json : Json, path : @json.JsonPath, known : (Int) -> T?, unknown : (Int) -> T) -> T raise @json.JsonDecodeError
```

規則:
- `ObjBuilder` は挿入順を保つ。同じキーを二度書いたら後勝ち(位置は最初のまま)。メソッドは `self` を返して連鎖できる(可変ビルダ)。
- `field`: キーが無い、または値の型が合わなければ `JsonDecodeError`。エラーの path は `path` にキーを足したもの。
- `opt_field`: キーが無い、または値が `null` なら `None`。
- `presence_field`: キーが無ければ `Absent`、`null` なら `Null`、それ以外は `Value`。
- `open_string` / `open_int`: open enum のデコード補助。`known` が `Some` を返せばそれ、`None` なら `unknown(raw)` を使う。JSON の型が文字列(整数)でなければ `JsonDecodeError`。`open_int` は小数部のある数値と `Int` に収まらない数値を拒否する。
  使い方: `enum FinishReason { Stop; Length; Unknown(String) }` に対し `open_string(json, path, s => match s { "stop" => Some(Stop); "length" => Some(Length); _ => None }, s => Unknown(s))`。上流が値を増やしてもデコードが落ちない。

`@json.JsonPath` / `@json.JsonDecodeError` の正確な名前と組み立て方は `moonbitlang/core/json` の現行 API に合わせる(違っていたら最も近い形にして報告)。

## 3b の公開 API(契約)

前提: 依存ゼロのモジュールは `async test` を実行できない(`moonbitlang/async` が要る)。テスト用の import でもモジュールの依存に入るので、async の実行テストは **公開しないモジュール `runtime-tests/`(`gaato/mbt-sdk-runtime-tests`)** に置く。`sdk-runtime` 側は純粋関数のテストとコンパイル確認まで。

### `gaato/http/clock`(新パッケージ。時間も IO なので sans-IO の語彙に置く)

```moonbit
pub(open) trait Clock {
  async fn sleep(Self, Int) -> Unit        // ミリ秒。0 以下は即戻る。エラーは上げない(`noraise` が書けるなら付ける)
  fn now_unix_ms(Self) -> Int64
}
```
`gaato/http/mock` に追加: `pub struct FakeClock`、`FakeClock::new(start_unix_ms? : Int64 = 0L)`、`impl Clock`(`sleep` は待たずに時刻を進めて記録)、`FakeClock::slept(Self) -> Array[Int]`、`FakeClock::advance(Self, Int) -> Unit`。
`gaato/http-async` に追加: `pub struct AsyncClock`、`AsyncClock::new()`、`impl @clock.Clock`(`@async.sleep` と壁時計。壁時計の取得元は core / async の現行 API から選んで報告)。

### `gaato/sdk-runtime`(root)

```moonbit
pub(all) enum Auth { NoAuth; Bearer(String); Header(String, String) }     // Debug は秘密を必ず伏せる("Bearer(<redacted>)")
pub fn Auth::apply(Self, @http.Request) -> @http.Request                  // 既に同名ヘッダがあれば上書きしない

pub(all) struct RetryPolicy { max_retries : Int; backoff : Backoff; max_retry_after_ms : Int; retry_non_idempotent : Bool } derive(Eq, Debug)
pub fn RetryPolicy::default() -> RetryPolicy          // 2, Backoff::default(), 60000, false
pub fn RetryPolicy::none() -> RetryPolicy             // max_retries 0
pub fn is_idempotent(@http.Request) -> Bool           // GET HEAD PUT DELETE OPTIONS TRACE、または idempotency-key ヘッダあり
pub fn RetryPolicy::next_delay_ms(Self, error : SdkError, request : @http.Request, attempt : Int, random : Double) -> Int?   // 純粋。再試行しないなら None

pub(all) struct RateLimitState { remaining : Int; reset_at_unix_ms : Int64 } derive(Eq, Debug)
pub(open) trait RateLimiter {
  async fn acquire(Self, String) -> Unit                                   // bucket
  fn observe(Self, String, Int, @http.Headers, Int64) -> Unit              // bucket, status, headers, now_unix_ms
}
pub struct NoLimiter;  pub fn NoLimiter::new() -> NoLimiter;  impl RateLimiter
pub struct WindowLimiter
pub fn WindowLimiter::new(clock : &@clock.Clock, parse : (@http.Headers, Int64) -> RateLimitState?) -> WindowLimiter
impl RateLimiter for WindowLimiter
pub fn WindowLimiter::state(Self, String) -> RateLimitState?
pub fn rate_limit_headers(remaining~ : String, reset_after_seconds? : String, reset_unix_seconds? : String) -> (@http.Headers, Int64) -> RateLimitState?

pub struct Client
pub fn Client::new(
  transport : &@http.Transport, clock : &@clock.Clock, base_url~ : String,
  default_headers? : @http.Headers, auth? : Auth, retry? : RetryPolicy,
  limiter? : &RateLimiter, middleware? : Array[@http.Middleware], random? : () -> Double,
) -> Client
pub async fn Client::send(Self, @http.Request, bucket? : String) -> @http.Response raise SdkError
pub async fn Client::send_json(Self, @http.Request, bucket? : String) -> Json raise SdkError
pub async fn Client::send_stream(Self, @http.Request, bucket? : String) -> (@http.ResponseHead, &@http.BodyStream) raise SdkError

pub(all) struct Page[T] { items : Array[T]; next : String? }
pub struct Paginator[T]
pub fn[T] Paginator::new(fetch : async (String?) -> Page[T] raise SdkError) -> Paginator[T]
pub async fn[T] Paginator::next_page(Self[T]) -> Array[T]? raise SdkError
pub async fn[T] Paginator::each(Self[T], async (T) -> Unit raise SdkError) -> Unit raise SdkError
pub async fn[T] Paginator::collect(Self[T], max~ : Int) -> Array[T] raise SdkError
pub fn parse_link_next(@http.Headers) -> String?      // RFC 8288 の Link ヘッダから rel="next" の URL
```

規則:
- `Client::send` の順序: (1) URL 解決(`request.url` が `http://` / `https://` で始まれば そのまま、そうでなければ `base_url` と `/` が重複も欠落もしないように連結)(2) `default_headers` を「要求に同名が無いものだけ」足す (3) `auth.apply` (4) ここから再試行ループ: `limiter.acquire(bucket)` → `send_with(transport, middleware, request)` → `limiter.observe(bucket, status, headers, now)` → `classify`。`HttpError` は `SdkError::Transport` に包む。(5) 失敗したら `retry.next_delay_ms(...)` が `Some(ms)` のとき `clock.sleep(ms)` して次の試行、`None` ならそのエラーを上げる。`bucket` の既定は `""`。`random` の既定は core に全ターゲットで使える乱数があればそれ、無ければ定数 0.5(報告する)。
- `next_delay_ms`: `attempt`(0 始まり、これまでに失敗した回数 − 1)が `max_retries` 以上なら `None`。`error.is_retryable()` が false なら `None`。要求が冪等でなく `retry_non_idempotent` も false なら `None`。ただし `RateLimited` と `Transport(Connect(_))` は「サーバが処理していない」ので冪等でなくても再試行する。待ち時間は `RateLimited(retry_after_ms=Some(ms))` なら `ms`(`max_retry_after_ms` を超えたら再試行せず `None`)、`Status` で `retry_after_ms(headers)` が取れればそれ(同じ上限)、それ以外は `backoff.delay_ms(attempt, random)`。
- `send_json`: `send` の後、本文が空(204 など)なら `Json::null()`、JSON として不正なら `SdkError::Decode`。
- `send_stream`: 応答ヘッダを受け取るまでは `send` と同じ再試行。2xx ならストリームを返す。2xx 以外なら本文を最大 1 MiB まで読んで close し、`classify` と同じ分類でエラーにする(それも再試行の対象)。ストリームを返した後の失敗は再試行しない。
- `WindowLimiter`: `observe` は `parse` が `Some` を返せばそのバケットの状態を置き換える。429 のときは、`retry_after_ms(headers, now)` が取れれば `remaining = 0`、`reset_at = now + ms` にする(`parse` の結果より優先)。`acquire` は、状態が無いか `remaining > 0` か `now >= reset_at` なら通す(`remaining > 0` なら 1 減らす。`now >= reset_at` なら状態を消す)。そうでなければ `clock.sleep(reset_at - now)` して再判定をループする。協調的マルチタスクで `sleep` の間に別の要求が状態を変える前提で書く。
- `rate_limit_headers`: `remaining` ヘッダが非負整数として読めなければ `None`。`reset_after_seconds`(小数秒可)があれば `now + 秒`、無ければ `reset_unix_seconds`(小数秒可の Unix 秒)。どちらも読めなければ `None`。OpenAI の `6m0s` 形式は扱わない(SDK 側が自前の `parse` を渡す)。
- `Paginator`: `fetch(None)` が最初のページ。`next` が `None` になったら終わりで、以後 `next_page` は `None`。空の `items` でも `next` があれば続ける。`collect(max~)` は `max` 件に達したら打ち切る(余りは捨てる)。`fetch` が失敗したら状態を進めず、同じカーソルで再度呼べる。
- `parse_link_next`: 複数の `Link` ヘッダ値とカンマ区切りの両方を扱う。`rel` は引用符あり/なし、複数 rel(`rel="next last"`)を扱う。`<>` の中のカンマで分割しない。

### テスト
- `sdk-runtime` 内(全ターゲットで実行): `Auth` の redaction と上書きしない規則、`is_idempotent`、`next_delay_ms` の表(各エラー × 冪等/非冪等 × attempt × retry-after の有無と上限超え)、`rate_limit_headers`、`parse_link_next`、`RetryPolicy` の既定値。async な API はコンパイル確認。
- `runtime-tests/`(native と js で実行。`FakeTransport` と `FakeClock` を使い、ソケットは使わない): `Client::send` の URL 解決とヘッダ/認証の注入、500 → 500 → 200 で 2 回 sleep して成功、`max_retries` 到達で最後のエラー、POST は 500 を再試行しないが 429 と Connect は再試行、`idempotency-key` 付き POST は再試行、`retry-after` が上限超えなら再試行しない、`send_json` の空本文と不正 JSON、`send_stream` の 2xx と 非 2xx(本文が分類に入ること、ストリームが close されること)、`WindowLimiter` が枯渇時に `reset_at` まで sleep すること・429 の `retry-after` を反映すること・バケットが独立なこと、`Paginator` の全規則、`AsyncClock` の sleep と時刻(native のみ、期限つき)。

## 3c の公開 API(契約)— `gaato/sdk-runtime/multipart`(純粋)

```moonbit
pub(all) struct Part { name : String; filename : String?; content_type : String?; body : Bytes } derive(Eq, Debug)
pub fn Part::text(name : String, value : String) -> Part                     // UTF-8、content_type なし
pub fn Part::file(name : String, filename : String, content_type : String, body : Bytes) -> Part
pub fn Part::json(name : String, value : Json) -> Part                       // content_type application/json
pub(all) suberror MultipartError { InvalidBoundary(String); BoundaryCollision; InvalidHeaderValue(String) } derive(Debug)
pub fn encode(parts : Array[Part], boundary : String) -> (String, Bytes) raise MultipartError   // (content-type ヘッダ値, 本文)
pub fn make_boundary(random : () -> Double) -> String                        // 先頭 "mbt-sdk-"、続けて 32 文字の [0-9a-z]
pub fn apply(request : @http.Request, parts : Array[Part], boundary : String) -> @http.Request raise MultipartError
```
規則: boundary は RFC 2046 の bchars で 1–70 文字、末尾が空白でないこと。各パートは `--boundary CRLF`、`Content-Disposition: form-data; name="..."[; filename="..."] CRLF`、`Content-Type: ... CRLF`(あれば)、空行、本文、`CRLF`。最後に `--boundary-- CRLF`。`name` / `filename` は WHATWG の multipart/form-data 符号化に従い `"` → `%22`、CR → `%0D`、LF → `%0A` に置換して UTF-8 のまま書く。`content_type` に CR / LF があれば `InvalidHeaderValue`。どれかのパート本文に `CRLF--boundary` が含まれる(または本文が `--boundary` で始まる)なら `BoundaryCollision`。content-type ヘッダ値は `multipart/form-data; boundary=<boundary>`(bchars のうち引用が要る文字を含むときだけ引用符で囲む)。`apply` は本文と `content-type` を設定した新しい `Request` を返す(既存の `content-type` は置き換える)。パート 0 個も有効(終端だけ)。

## 3a の判断

- 数値は ASCII の `digits` / `digits.digits` のみ。符号、指数表記、`.5`、`1.` は拒否する。前後は core の `String::trim` で除去する。秒は小数 3 桁まで、ミリ秒ヘッダは整数部分まで使い、切り捨てる。飽和後も末尾まで検証して不正文字を拒否する。
- `retry-after-ms` が無い、または解釈できないときは `retry-after` にフォールバックする(OpenAI 公式 SDK の挙動に合わせ、レビューで Codex の初期判断から変更)。どちらも解釈できなければ `None`。同名の複数値は `Headers::get` に合わせて最初の値を使う。
- IMF-fixdate は固定桁数・英語の曜日/月・大文字 `GMT` を要求し、年 0001–9999、実在する月日、曜日との一致を検証する。Gregorian の 400 年周期を自前で計算する。秒 60 は受理し、Unix 時刻では次の秒として扱う(うるう秒表は持たない)。Int64 の最小/最大の現在時刻でも、比較を先に行い差分のオーバーフローを避ける。
- backoff は raw を Double のまま cap と jitter に使い、最後にミリ秒未満を切り捨てる。random の上限は 1 未満の最大 Double (`0.9999999999999999`)、負値・NaN は 0。丸め誤差により jitter 上限と同じ結果になる場合もある(既定値の範囲外 random → 600ms)。巨大な attempt は `@math.pow` の無限大を cap して処理する。
- backoff の契約に範囲指定がない設定値について、負の base/max は 0、負値・NaN の factor は 0、jitter は [0, 1] に収める(NaN は 0)。base/max が 0 の場合は先に 0 を返し、`0 * Infinity` を避ける。公開の設定検証 API は追加しない。
- `ObjBuilder::build` は Map のコピーを返すため、後のビルダ更新で既存のオブジェクトのフィールドは変わらない(JSON の値自体の深いコピーはしない)。`opt(None)` / `presence(Absent)` は既存キーも削除せず無操作。順序と上書きは core の挿入順 Map を使う。
- required `field` は null を一律拒否せず `T` の FromJson に従う(`String` はエラー、`String?` は None)。`open_int` は core の Int デコーダが小数を切り捨てるため、独自に範囲と整数性を検査する。数値として整数なら `1.0`、`-0.0`、指数表記由来の JSON 数値も受理する。
- core の正確な型は `@json.JsonPath` と `@json.JsonDecodeError`、エラー構築は `@json.JsonDecodeError((path, message))`、キー追加は `path.add_key(key)`。JsonPath は外部には抽象型で Root コンストラクタは公開されない。利用例・テストは `@json.from_json` が `FromJson::from_json(json, path)` に渡す path を受け取る。JSON 構築には読み取り専用 enum のコンストラクタでなく `Json::null()` / `Json::object(...)` を使う。
- toolchain `0.1.20260920` で `pub fn[T : @json.FromJson]` / `pub fn[T : ToJson]` は契約どおりコンパイルする。明示的な trait メソッド公開は `pub extend Presence with Eq::{equal, not_equal}` 等とし、型パラメータの制約は derive から引き継ぐ。公開 API の追加・変更はない(規約で要求される derive の明示的 extend を含む)。
