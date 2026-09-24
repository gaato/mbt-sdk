# 設計メモ — M9: `gaato/sdk-runtime` 0.2.0(discord.mbt を載せるための契約変更)

目的は 1 つ。`gaato/discord`(discord.mbt)の REST 層を `gaato/sdk-runtime` の `Client` に載せ替えられるようにする。discord.mbt は `gaato/http` の語彙(`Transport`、`Request`/`Response`)はすでに使っているが、その上の送信ループ・rate limiter・retry・telemetry・multipart・paginator を独自に持っている。`docs/design.md` にあるとおり、runtime の middleware / `Paginator` / `RateLimiter` はもともと discord.mbt から着想を得たもので、分岐したまま育っていた。

## なぜ runtime 側を変えるのか

discord.mbt を今の runtime にそのまま載せると、次の 3 つで挙動が劣化する。いずれも Discord API の性質に由来する discord.mbt 側の意図的な設計で、runtime に無いものだった。

| discord.mbt の契約 | 0.1.0 の runtime |
|---|---|
| `acquire` ごとに必ず 1 回 `release`(応答が無ければ status 0)。bucket ごとの gate を取引の間ずっと握るので、対が崩れると deadlock する | `acquire` / `observe`。transport が失敗すると `observe` が呼ばれない。streaming は head 到着後にしか `observe` しない |
| アカウント全体の 50 req/s 窓と、interaction endpoint の global 除外 | global の概念が無い |
| 再送は 429 だけ。Timeout は「届いた可能性がある」ので POST でも GET でも再送しない | `RetryPolicy` は固定ロジックで、Timeout と 5xx を idempotent なら再送する |
| 試行ごとの telemetry(bucket、status、所要時間、何回目か)。429 は back-off の前に観測される | フックが無い |

「discord.mbt の方を runtime に合わせる」選択肢は取らなかった。上の 3 つはどれも Discord のドキュメントに根拠がある挙動で、劣化を受け入れる理由が無い。runtime は API 非依存であるべきなので、Discord 固有の値(50 req/s、`x-ratelimit-global`)は入れず、**それを表現できる契約**だけを足した。

## 変更

### `RateLimiter`: `observe` → `release`、`global_exempt`

```moonbit
pub(open) trait RateLimiter {
  async fn acquire(Self, String, global_exempt~ : Bool) -> Unit
  async fn release(Self, String, status~ : Int, headers~ : @http.Headers) -> Unit
}
```

- `acquire` は raise できる(別プロセスの limiter に届かない等)。raise した場合、リクエストは送られずに `Config` として失敗する。
- `acquire` が返ったら、`Client` は必ず 1 回 `release` を呼ぶ。応答があれば status とヘッダ、無ければ `status=0` と空ヘッダ。buffered / streaming の両方で同じ。
- `release` は `raise` できる(cross-process の limiter が lease 欠落を報告する)。成功経路の raise は `Config` として呼び出し側に届き、失敗経路(すでに attempt が失敗している)の raise は捨てる。
- **キャンセル**: `moonbitlang/async` のキャンセルは `catch` には見えないが `defer`/`errdefer` は走る。runtime は async runtime を import しないので `protect_from_cancel` は使えない。そのため契約として「キャンセル中の `release` は途中で打ち切られうるので、await する実装は自力で回復する」と決めた(discord.mbt の `RemoteRateLimiter` は接続を落としてサーバの EOF 掃除に任せる)。in-memory の limiter は await しないので影響がない。
- `acquire` の中でキャンセルされた場合は何も admit されていないので `release` は呼ばない。
- 応答を受け取った後の `release` が raise するか、キャンセルで打ち切られた場合、その応答は呼び出し側に渡らない。streaming では本文の stream を runtime が閉じる(`errdefer` で `close`)。呼び出し側は受け取っていない stream を閉じられないためである。
- `global_exempt` は「アカウント全体の制限に数えない」の意味。`WindowLimiter` / `NoLimiter` は無視する。bucket 文字列に埋め込む案(先頭 `!` など)は、意味のあるフラグを文字列に隠すことになるので却下した。
- `WindowLimiter::release` は `status=0` を無視する。時刻は `Client` から渡さず、自分の `Clock` から取る。

### `RetryDecider`: 判断を trait にする

```moonbit
pub(open) trait RetryDecider {
  fn next_delay_ms(Self, SdkError, @http.Request, Int, Double) -> Int?
}
```

`RetryPolicy` はこの trait の既定実装になった(`pub extend` で dot 呼び出しはそのまま)。`Client::new(retry? : &RetryDecider)`。struct に関数フィールドを足す案は `pub(all)` + `derive(Eq, Debug)` + struct-update の既存利用と衝突するので、trait の方が変更が小さい。openai / anthropic / github の facade は `retry? : RetryPolicy` のまま(内部で `&RetryDecider` に変換)。

### `observer`: 試行ごとのフック

`Client::new(observer? : (Attempt) -> Unit)`。`Attempt` は bucket、送った `Request`、0 始まりの試行番号、status(応答が無ければ 0)、ヘッダ、本文(streaming では呼び出し側のものなので空)、所要時間、`SdkError?`。本文を含めるのは、Discord の 429 が待ち時間をヘッダより細かい精度で本文の `retry_after` に書くため。呼ぶ位置は「`release` の直後、retry 判断の前」。この位置なら discord.mbt は 1 つの observer から `HttpRequest` と `HttpRateLimited` を順に出せて、429 の観測が back-off sleep より前になる。observer は raise しない型(`-> Unit`)。observer は `defer` で呼ぶ。そうすれば、`release` が await 中にキャンセルで打ち切られても、その試行は必ず 1 回観測される。

### `Paginator[T, E]`

- エラー型を総称化した。SDK は自分のエラー型(discord.mbt なら `DiscordHttpError`)をそのまま `raise` できる。struct の型引数に `Error` 境界は付けられないので、fetch は `Result` を返す形で保持し、境界はメソッド側に置いた。
- 構築は 2 つに分けた。`Paginator::new(fetch : async () -> Array[T]? raise E)` は cursor を fetch 側の closure に持たせる一般形で、snowflake・timestamp など文字列でない cursor の API(Discord)がそのまま載る。`Paginator::with_cursor(fetch : async (String?) -> Page[T] raise E)` は 0.1.0 の `new` と同じ文字列 cursor 形で、GitHub の `Link` と GraphQL の `endCursor` はこちら。`with_cursor` は `new` の上に実装してある。
- `collect(max~)` は使い切らなかったページの残りを保持し、次の `next_page` で返す。0.1.0 は捨てていた。取ってきたものを捨てる理由が無い。
- 空ページで終端とみなす。0.1.0 は cursor が無くなるまで続けていた。空ページに next cursor が付く API は想定していない。

### `multipart::encode_segments`

`encode` と同じ本文を、1 つの `Bytes` ではなく順序付きの断片の列で返す。各 part の本文はそのままの `Bytes` で 1 断片になり、コピーされない。discord.mbt の interaction callback は添付を含む応答を `ReadableStream` や socket へ断片ごとに流すので、大きな添付を一度連結する形にはできなかった。`encode` は `encode_segments` の連結として実装し、出力は 0.1.0 とバイト単位で同じ。

### 遅延本文 `body?`(0.2.1)

`send` / `send_json` / `send_stream` は `body? : () -> Bytes` を取る。与えると、各試行で limiter が admit した後に呼んで、その戻り値を本文にする。0.2.0 は `@http.Request` を完成させてから `acquire` で待つので、rate limit の待ち行列に並んだ multipart upload がそれぞれ符号化済みの本文を丸ごと 1 つ抱えていた。discord.mbt の旧実装は admit の後で符号化していたので、載せ替えで待機中のメモリが増えていた(Codex レビューで発覚)。

- 本文だけを遅らせる。method・URL・headers(boundary 入りの `content-type` を含む)は最初に確定しているので、retry decider は本文なしの request を見る。decider が要るのは method と headers だけ。observer は実際に送った request を見る。
- closure は raise しない。検証は admit の前に済ませる。multipart なら `encode_segments` を先に呼ぶと、boundary の衝突と header 値の検査が終わり、part の本文はコピーされずに断片として残る。closure はその連結だけをする。
- 試行ごとに呼ぶので、429 の再送でも待機中に本文を抱えない。

### streaming の残課題

`send_stream_once` は `release` の対を修正したが、middleware は今も通らない(`@http.send_with` が buffered 専用)。直すなら `gaato/http` 側で streaming 用の chain が要る。今回は触らない。

## 破壊的変更と移行

sdk-runtime 0.1.0 → 0.2.0。github は `Paginator` の型が変わるので 0.2.0 → 0.3.0。openai / anthropic は公開 API 不変。追加(`RetryDecider`、`Attempt`、`observer`、`global_exempt`、`encode_segments`)は後方互換。

| 変更 | 移行 |
|---|---|
| `RateLimiter::observe(bucket, status, headers, now)` → `release(bucket, status~, headers~)` | 引数をラベル付きに。時刻は `Clock` から取る。`status=0` を無視するか、gate を返すか決める |
| `RateLimiter::acquire(bucket)` → `acquire(bucket, global_exempt~)` | 引数を足す。global 制限が無ければ無視 |
| `Client::new(retry? : RetryPolicy)` → `retry? : &RetryDecider` | `RetryPolicy` 値はそのまま渡せる(`&RetryDecider` に上がる)。`Option` で持っている場合は `.map(p => p)` で型を付け直す |
| `Paginator[T]` → `Paginator[T, E]` | 戻り型に `@runtime.SdkError` を足す |
| `Paginator::new(cursor => Page)` → `Paginator::with_cursor(cursor => Page)` | 名前を変える。`new` は cursor を closure に持つ形になった |
| `Paginator::collect` が残りを捨てなくなった | 続けて `next_page` を呼ぶコードは残りを先に受け取る |
| 空ページで `next_page` が `None` | 空ページを `Some([])` として扱っていたコードを直す |
