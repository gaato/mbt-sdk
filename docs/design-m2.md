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
- `retry_after_ms`: `retry-after-ms` ヘッダ(非負の 10 進整数または小数のミリ秒。OpenAI が送る)を先に見て、無ければ `retry-after` を `parse_retry_after` に渡す。
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

## 3b / 3c(概要のみ。着手時に契約を書く)

- 3b: `pub(open) trait Clock { async fn sleep(Self, Int) -> Unit; fn now_unix_ms(Self) -> Int64 }`、`FakeClock`、retry middleware(`Backoff` と `retry_after_ms` を使い、冪等なメソッドか冪等キー付きの要求だけ再試行)、`RateLimiter` trait と in-memory 実装、`Paginator[T]`、認証ヘッダの注入、`gaato/http-async` に `AsyncClock`。
- 3c: `multipart/form-data` の writer(境界の生成は乱数を注入)。`Yoorkin/multipart` を先に評価する。
