# 設計メモ — M7: `gaato/jsonrpc` と `gaato/jsonrpc-async`(JSON-RPC 2.0 の語彙と stdio 接続)

背景(2026-09-22): coding agent を外から操るプロトコルは、Codex の `codex app-server`(v2 スキーマ: client 要求 102、server 通知 82、server→client 要求 10)も Zed/JetBrains の Agent Client Protocol(ACP、protocol version 1)も **改行区切り JSON(NDJSON)の JSON-RPC 2.0 を stdio で双方向に流す** 形で共通している。両方の SDK を後で載せられるよう、まず共通の下層を切る。HTTP 層と同じく sans-IO の語彙と transport を別モジュールに分ける(import はモジュール全体に効くため)。

二つの実装の差(一次資料: `codex app-server generate-json-schema` の出力と ACP の `schema/v1/schema.json`):

| | codex app-server | ACP v1 |
|---|---|---|
| `"jsonrpc": "2.0"` | **付けない**(スキーマに存在しない) | 必須 |
| `id` | string または int64 | null / int64 / string |
| 要求の追加メンバ | `trace`(W3C Trace Context、任意) | なし(`_meta` は params/result の中) |
| params | `true`(任意の JSON) | object |
| batch | 使わない | 使わない |

## 1. `gaato/jsonrpc`(依存ゼロ、wasm-gc / native / js)

ルートパッケージ 1 つ。`moonbitlang/core` 以外を import しない。

```moonbit
pub(all) enum RequestId { Number(Int64); Str(String); Null } derive(Eq, Debug, Hash)
pub impl ToJson for RequestId;  pub impl @json.FromJson for RequestId

pub(all) struct RpcError { code : Int; message : String; data : Json? } derive(Eq, Debug)
pub impl ToJson for RpcError;  pub impl @json.FromJson for RpcError
pub fn RpcError::new(code~ : Int, message~ : String, data? : Json) -> RpcError
// 仕様の予約コード。message は仕様の既定文言(引数で上書き可)、data は None
pub fn RpcError::parse_error(message? : String) -> RpcError        // -32700 "Parse error"
pub fn RpcError::invalid_request(message? : String) -> RpcError    // -32600 "Invalid Request"
pub fn RpcError::method_not_found(method : String) -> RpcError     // -32601 "Method not found"、data = method
pub fn RpcError::invalid_params(message? : String) -> RpcError     // -32602 "Invalid params"
pub fn RpcError::internal_error(message? : String) -> RpcError     // -32603 "Internal error"

pub(all) enum Message {
  Request(id~ : RequestId, name~ : String, params~ : Json?)        // name = JSON-RPC の method(`method` は MoonBit の予約語なのでラベルは name)
  Notification(name~ : String, params~ : Json?)
  Response(id~ : RequestId, result~ : Json)
  Failure(id~ : RequestId, error~ : RpcError)
} derive(Eq, Debug)

pub(all) enum Envelope { Strict; Bare } derive(Eq, Debug)
// Strict = "jsonrpc":"2.0" を送り、受信でも要求する(ACP、MCP、LSP)
// Bare   = 送らない。受信は無くても "2.0" でもよい(codex app-server)

pub fn Message::to_json(Self, envelope~ : Envelope) -> Json
pub fn Message::from_json(Json, envelope~ : Envelope) -> Message raise DecodeError
pub fn Message::encode(Self, envelope~ : Envelope) -> Bytes      // compact JSON + "\n"(NDJSON 1 行)
pub fn decode_line(Bytes, envelope~ : Envelope) -> Message raise DecodeError   // UTF-8 → JSON → from_json

pub(all) suberror DecodeError {
  InvalidJson(String)      // UTF-8 不正、JSON として読めない
  InvalidMessage(String)   // JSON ではあるが JSON-RPC 2.0 のメッセージでない(理由を人が読める文で)
  LineTooLong(Int)         // LineFramer の max_line 超過(値は上限)
} derive(Eq, Debug)

pub struct LineFramer                                // 増分の行分割器。ストリーム 1 本につき 1 つ
pub fn LineFramer::new(max_line? : Int) -> LineFramer   // None = 上限なし(既定)
pub fn LineFramer::feed(Self, Bytes) -> Array[Bytes] raise DecodeError   // チャンク境界は任意。完成した行を順に返す
pub fn LineFramer::finish(Self) -> Bytes?             // 改行で終わっていない末尾(空白のみなら None)。以後 feed は [] を返す
```

デコードの規則(`from_json`):
- オブジェクト以外(配列 = batch を含む)は `InvalidMessage`。batch はどの相手も使わないので対応しない。
- `jsonrpc`: Strict では `"2.0"` 必須。Bare では無いか `"2.0"`。それ以外の値はどちらでも `InvalidMessage`。
- `method` があれば要求か通知。`id` メンバが **存在すれば**(null でも)`Request`、無ければ `Notification`。`method` は文字列でなければ `InvalidMessage`。
- `method` が無ければ応答。`error` があれば `Failure`、無くて `result` があれば `Response`。両方ある・両方ない・`id` が無いのは `InvalidMessage`。`result` は null でもよい(`Response(result=Null)`)。
- `id`: 整数値の数(小数部なし)は `Number`、文字列は `Str`、null は `Null`。小数・真偽・オブジェクトは `InvalidMessage`。2^53 を超える整数は `Json` の Double 経由で精度が落ちる(既知の制限、相手は連番なので実害なし)。
- `params`: 存在すれば型を問わずそのまま `Some`(codex は `true`)。無ければ `None`。
- `error`: `code`(整数)と `message`(文字列)必須、`data` 任意。欠けていれば `InvalidMessage`。
- 未知のトップレベルメンバ(codex の `trace` など)は無視する。エンコード側でも出さない(必要になった消費者が契約を足す)。

エンコードの規則(`to_json` / `encode`):
- キー順は固定: `jsonrpc`(Strict のみ)→ `id` → `method` → `params` / `result` / `error`。`params` は `Some` のときだけ。`error.data` は `Some` のときだけ。
- `encode` は `Json::stringify` の compact 出力に `\n` を 1 つ付ける。出力に生の改行が含まれないこと(stringify は制御文字をエスケープする)をテストで固定する。

LineFramer の規則:
- 区切りは `\n`。行末の `\r` は 1 つだけ除く(`\r\n` 対応)。UTF-8 の多バイト文字が境界で割れても壊れない(バイトで溜めて行単位で返す)。
- 空行・空白(スペース、タブ、`\r`)だけの行は返さない。
- `max_line` を超えた時点で `LineTooLong` を raise し、以後は終端状態(`feed` は `[]`、`finish` は `None`)。
- `finish` は未完の末尾を返す(相手が最後の改行を書かずに終了する場合に備える)。繰り返し呼べる(2 回目以降は `None`)。

## 2. `gaato/jsonrpc-async`(`gaato/jsonrpc` + `moonbitlang/async`、js + native)

```moonbit
pub(all) suberror RpcFailure {
  Remote(RpcError)     // 相手が error 応答を返した
  Transport(String)    // 書き込み失敗、EOF 前の切断、読み取り中の IO エラー
  Timeout(Int)         // call の timeout_ms 超過
  Closed               // 接続が閉じている(呼び出し前に閉じていた、または待機中に閉じた)
} derive(Debug)

pub type RequestHandler = async (String, Json?) -> Result[Json, RpcError]   // (method, params) → 応答
pub type NotificationHandler = async (String, Json?) -> Unit

pub struct Connection
pub fn[X] Connection::start(
  group : @async.TaskGroup[X],
  reader : &@io.Reader,
  writer : &@io.Writer,
  close_writer? : () -> Unit,            // 既定: 何もしない。`&@io.Writer` に close が無いので、EOF を送りたい呼び出し側が渡す(pipe なら PipeWrite::close)
  envelope? : Envelope = Strict,
  max_line? : Int,
  on_request? : RequestHandler,          // 既定: method_not_found を返す
  on_notification? : NotificationHandler // 既定: 捨てる
) -> Connection
pub async fn Connection::call(Self, method : String, params? : Json, timeout_ms? : Int) -> Json raise RpcFailure
pub async fn Connection::notify(Self, method : String, params? : Json) -> Unit raise RpcFailure
pub fn Connection::close(Self) -> Unit          // writer を閉じ、待機中の call を Closed で失敗させる。冪等
pub fn Connection::is_closed(Self) -> Bool
pub fn Connection::decode_errors(Self) -> Int   // 受信側で捨てた不正行の数(テストと診断用)
```

native 限定(`options(targets:)` で `child.mbt` を native に限定。js では存在しない):

```moonbit
pub struct Child { connection : Connection; process : @process.Process }
pub async fn[X] spawn_child(
  group : @async.TaskGroup[X],
  program : String,
  args : Array[String],
  cwd? : String,
  extra_env? : Map[String, String],
  stderr? : &@process.ProcessOutput,     // 既定: 親の stderr を継承(agent はログを stderr に書く)
  envelope? : Envelope = Strict,
  max_line? : Int,
  on_request? : RequestHandler,
  on_notification? : NotificationHandler
) -> Child raise
pub async fn Child::shutdown(Self, timeout_ms? : Int = 5000) -> Int
// stdin を閉じて timeout_ms 以内の終了を待つ。間に合わなければ `process.cancel()` で止めてから待つ。終了コードを返す
```

Connection の判断:
- `start` は読み取りループを `group.spawn_bg(no_wait=true, ...)` で起動する。`no_wait` にするのは、利用者の本体が終わったらループも終わってよいから(ループが EOF を待ち続けてグループが返らないのを避ける)。ループはグループのキャンセルでそのまま止まる。
- **読み取りループは決してハンドラで塞がらない**。受信メッセージの振り分けだけを行う:
  - `Response` / `Failure` → `id` で待機中の `call` を解決する。未知の `id` は捨てる(`decode_errors` には数えない)。
  - `Request` → ハンドラを同じグループのタスクとして **並行に** 起動する(承認要求は人の応答を待つ間、他の通知が流れ続けるため。ハンドラの中で `call` してもデッドロックしない)。`Ok(json)` → `Response`、`Err(e)` → `Failure`。ハンドラが raise した場合は `internal_error(エラー文字列)` を返信したうえで、その Error をループの失敗として伝播する(ハンドラの raise はバグ扱い。相手に見せる失敗は `Err` で返す)。
  - `Notification` → 順序保存の unbounded `@aqueue.Queue` に積み、専用のディスパッチタスク 1 本が **FIFO で逐次** ハンドラを呼ぶ(ACP の session/update も codex の turn イベントも順序に意味がある)。ハンドラの raise は上と同じくループの失敗として伝播する。
- `id` は `Number` の 1 からの連番(接続ごと)。
- 書き込みは `@async.Mutex` で直列化し、1 メッセージ = `encode` した 1 行をまとめて `write` する(複数タスクからの `call` / `notify` が行の途中で混ざらない)。
- `call` の待機は内部機構に任せる(待機中 call ごとの `@aqueue.Queue` か `Cond`)。`timeout_ms` は `@async.with_timeout` で掛け、期限切れは待機表から外して `Timeout(ms)`。`timeout_ms` 省略は無期限(agent の turn は長い)。キャンセルは HTTP 層と同じく Error にしない: 伝播させ、`defer` で待機表から外す。
- 不正行の扱い: 読めない行(UTF-8 / JSON 不正)は `Failure(id=Null, parse_error)` を、JSON だが JSON-RPC でない行は `Failure(id=Null, invalid_request)` を返信して **続行** し、`decode_errors` を増やす。agent CLI が stdout にログを混ぜる事故で接続を落とさないため。`LineTooLong` だけは復旧不能なので `Transport` でループを終える。
- EOF: `finish()` の末尾が空白以外なら最後のメッセージとして処理する。その後、待機中の `call` を全部 `Closed` で失敗させ、`is_closed` を真にし、ループは正常終了する。以後の `call` / `notify` は `Closed`。読み取り中の IO エラーは `Transport` として待機中の call を失敗させ、ループはその Error を伝播する。
- `close` は `close_writer` を呼び(子プロセスなら stdin の EOF。省略時は何もしない)、待機中の call を `Closed` にする。reader は閉じない(ループが EOF で自然に抜ける)。
- `spawn_child` は `@process.write_to_process()` / `@process.read_from_process()` で stdin / stdout をパイプにし、`@process.spawn(group, ...)` で起動、`Connection::start` を同じ group で始める(`close_writer` には `WriteToProcess::close` を渡す)。`stderr` 省略時は継承。

## 3. 検証

`gaato/jsonrpc`(3 ターゲット、純粋):
- jsonrpc.org の仕様書の例(位置引数、名前付き引数、通知、存在しないメソッド、不正 JSON、不正な Request)を Strict で往復させる。`Message::from_json(to_json(m)) == m`。
- codex の形(`jsonrpc` なし、`trace` 付き要求、`params: true` 相当の非オブジェクト params)を Bare で読み、Strict では `InvalidMessage` になる。
- `id`: `0`、負数、`"abc"`、null、`1.5`(拒否)、`true`(拒否)。`result: null` は `Response`。`result` と `error` の同居は拒否。
- `encode` の出力に `\n` が末尾以外にないこと(制御文字と U+2028 を含む文字列で確認)。
- LineFramer: SSE パーサと同じ「同じ入力を全バイト位置で 2 分割しても結果が同じ」総当たり(`\r\n`、空行、多バイト文字の分割を含む)。`max_line` 超過、`finish` の末尾。

`gaato/jsonrpc-async`(js + native、ソケット不要): `@io.pipe()` を 2 組使い、2 つの `Connection` を同一プロセス内で向かい合わせる。全 async テストを `@async.with_timeout(5000, ...)` で包む。
- 双方向の `call` を並行に多数発行し、`id` の混線がないこと(結果に要求内容を埋め込んで照合)。
- 通知 100 件が順序どおり届くこと。
- ハンドラの `Err` → `Remote`、既定ハンドラ → `method_not_found`、`timeout_ms` → `Timeout`。
- 相手が `close` → こちらの待機中 `call` が `Closed`、以後の `call` も `Closed`。
- 不正行(生テキスト、`{"foo":1}`)を混ぜても後続の `call` が通り、`decode_errors` が増え、相手に `Failure(Null, ...)` が届く。
- Strict 受信側に Bare 行を送ると `invalid_request` が返る。
- `call` の外側キャンセルが `catch` を素通りし、待機表から消える(その後の同 id 応答が捨てられる)。
- 要求ハンドラの中から相手に `call` してもデッドロックしない(往復の入れ子)。

native のみ: `spawn_child(group, "cat", [])`。`cat` は行をそのまま返すので、`notify` が `on_notification` に届き、`call("echo")` は自分の `on_request` に届いて返した応答が再び `cat` を経由して `call` を解決する(1 プロセスで往復全部を通す)。`shutdown` が 0 を返す。

## 4. ゲート

`jsonrpc` は `http` と同じ 3 ターゲットの check / test、`jsonrpc-async` は `http-async` と同じ native / js。`scripts/gates.sh` に組み込み済み。テストはワークスペース経由(`moon -C runtime-tests test --target X`)で全メンバー分が回る。

## 5. 実装中の契約修正(2026-09-22)

- Codex の指摘: `moonbitlang/async@0.22.1` の `@io.Writer` trait に `close` が無く、`&@io.Writer` だけでは `Connection::close` が EOF を送れない。→ `Connection::start` に `close_writer? : () -> Unit` を追加(上に反映済み)。
- `Message` のラベル `method~` は MoonBit の予約語警告(`reserved_keyword`)を抑止しないと使えないため `name~` に変更。警告抑止は入れない。
- EOF は受信側の終端として扱い、新しい `call` / `notify` は拒否するが、受信済み要求への返信は writer が開いている間は完了できる。最後の改行なし要求を処理してから EOF を扱う契約に合わせたもの。`EOF still permits a response to the final unterminated request` で確認。
- `timeout_ms` は送信と応答待ちの全体に適用し、0 以下は即時 `Timeout`。送信途中のキャンセルは行を途中まで書いた可能性があるため接続を閉じる。応答待ちだけのキャンセルは待機表から除去し、接続は再利用可能。
- 使用中の Moon は条件付き import 未対応なので、native 専用 `child.mbt` が使う `process` import は JS では未使用になる。`jsonrpc-async/src/moon.pkg` で `unused_package` のみ無効にし、ファイルのターゲット制限と native / JS の両検査で境界を確認する。`implicit_impl_as_method` は明示的な `extend` を定義して対処し、無効にしない。

## 6. M7 でやらないこと

- `Content-Length` ヘッダ枠(LSP 形式)。NDJSON しか相手がいない。
- WebSocket / unix socket の transport(`moonbitlang/async/websocket` はあるが、codex も ACP も既定は stdio)。
- 要求の `trace` / `_meta` の型付き扱い。
- codex app-server / ACP の型生成。JSON Schema の入口を `tools/gen` に足すのは次のマイルストーン。
