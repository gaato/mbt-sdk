# 設計メモ — M10: 再送判定の共通化、SDK を公式の挙動に合わせる、時間制限

目的は 3 つある。

1. `gaato/http` に再送判定の**仕組み**を置き、`sdk-runtime` と `gaato/requesto` から共有する。
2. 各 SDK を、提供元の公式 SDK とサーバー側の文書に沿った挙動に揃える。
3. `sdk-runtime` に時間制限を持たせる。

mbt-sdk は SDK を量産するための基盤なので、この挙動の合わせ込みを、次の SDK でも同じ手順で安く繰り返せる形にする。手順書は [new-sdk.md](new-sdk.md)、SDK ごとの調査結果は [behavior/](behavior/) にある。

## なぜ

2026-10-19 に `gaato/http`・`http-async`・`sdk-runtime`・`requesto` と、それを使う側(openai/anthropic/github、discord.mbt、nekosama、kbbi など)の責務を棚卸しした。分かったことは次のとおり。

- **再送判定が 2 か所に別々に書かれている。** `sdk-runtime` の `RetryPolicy` と `requesto` の `Retry` で、さらに github と discord がそれぞれ `RetryDecider` で拡張している。`gaato/http` にあるのは材料だけ(`is_idempotent`、`HttpError::is_unsent`、`retry_after_ms`)。
- **既定値の違いは意図したもの。** `requesto` は一般的な HTTP クライアント(Req の `:safe_transient`、ky、urllib3)に合わせ、409 を再送しない。`sdk-runtime` は Stainless 系 SDK に合わせ、409 を再送する(design-m2.md)。既定値を 1 つに揃えるのは間違った問いで、揃えるべきは仕組みのほうである。
- **SDK が公式とずれている。** 詳細は下の表と behavior/ にある。とくに anthropic は 529(過負荷)を一度も再送しない。
- **`sdk-runtime` に時間制限がない。** 純粋な層には取り消しの手段がないためで、その結果 discord.mbt は `AttemptDeadline` を自前で持っている。
- **利用者がいない。** `requesto` を使う利用者も、`@http.Middleware`・`redirects()`・`cookies()` を直接使う利用者も、まだ 1 つもない。実際に使われている組み立て方は、transport を包む方式(`DeadlineTransport`、discord の `ClosedGate`)だった。

## 原則: 「公式に合わせる」の中身

情報源を 3 種類に分け、重みを変える。

| 区分 | 何か | 扱い |
|---|---|---|
| A | サーバー側の文書(レート制限、エラー、ベストプラクティス、べき等キー) | 必ず従う。反していれば不具合 |
| B | 提供元自身が出している公式 SDK | A と矛盾しない範囲で合わせる。矛盾したら A を優先し、メモに残す |
| C | コミュニティのライブラリ | 参考にとどめる。利用者が慣れている挙動や落とし穴を知るために使う |

公式 SDK がない API(Discord)には B がない。一番よく使われているライブラリを B に格上げすることはしない。

## 決めたこと

1. **再送の仕組みは `gaato/http` に統一し、方針は層ごとに持つ。** 既定値は requesto、sdk-runtime のひな形、各 SDK がそれぞれ持つ。
2. **SDK は上の A/B/C の規則で公式に合わせる。**
3. **GitHub の POST は 5xx で再送しない。** octokit(B)は再送するが、GitHub にはべき等キーがない。Issue やコメントが二重に作られる害は、再送しない害より大きい。同じ理由で、GraphQL の "Something went wrong while executing your query" を再送するのは mutation 以外に限る。
4. **方針はデータとして宣言し、ひな形を用意する。** 新しい SDK は、ひな形を選んで値を調整するだけで済むようにする。コードを書くのは、規則で表せないもの(本文に書かれた待ち時間、メッセージで判定する特殊な制限)だけにする。
5. **`requesto` は MoonBit の公開ライブラリ(requests/httpx に当たるもの)にする。** ライブラリは `&Transport` と `Clock` を受け取り、`requesto` には依存しない。`requesto` を使うのはアプリの最上段だけ。`requesto` の `Client` に `@http.Transport` を実装させる案は、次の理由で却下した。
   - `send_stream` で本文の持ち主が噛み合わない
   - sdk-runtime の再送と二重になる
   - 層が混ざる

## 設計

### `gaato/http/retry`(新パッケージ。純粋で、依存は `gaato/http` だけ)

```moonbit
pub(all) enum StatusMatch { Code(Int); Range(Int, Int) }
pub(all) enum Methods { Never; Idempotent; Listed(Array[String]); Any }
pub(all) struct StatusRule { statuses : Array[StatusMatch]; methods : Methods }
pub(all) enum RetryAfterSource { Ignore; Header; MsThenHeader }
pub(all) enum RetryAfterCap { StopAbove(Int); BackoffAbove(Int); NoCap }
pub(all) struct RetryAfter { source : RetryAfterSource; cap : RetryAfterCap; zero_means_backoff : Bool }
pub(all) enum Jitter { NoJitter; Full; Proportional(lo~ : Int, hi~ : Int) } // 1000 分率
pub(all) struct Backoff { base_ms : Int; max_ms : Int; jitter : Jitter }    // 2 倍ずつ、整数演算、揺らぎの後も max_ms で切る
pub(all) struct RetryRule {
  max_retries : Int
  statuses : Array[StatusRule]   // 最初に一致した規則を使う
  sent_failures : Methods        // 送った後の失敗: Timeout(Write|Head|Body|Unknown)・Network
  unsent_failures : Bool         // 送っていない失敗: Connect・Timeout(Pool|Dial)
  override_header : String?      // 例: "x-should-retry"
  retry_after : RetryAfter
  backoff : Backoff
}
pub(all) enum Outcome { Response(status~ : Int, headers~ : @http.Headers); Failure(@http.HttpError) }
pub(all) enum Decision { Wait(Int); Stop(StopReason) }
// StopReason: Exhausted / NotRetryable / MethodNotAllowed / NotReplayable / ServerSaidNo / RetryAfterTooLong / Budget
// 値が増えうる enum(Methods・RetryAfterSource・RetryAfterCap・Jitter・StopReason)は #non_exhaustive
```

`RetryRule::decide(outcome, request, attempt~, random~, now_unix_ms?, remaining_ms?, server_delay_ms?, idempotent?, replayable?)` は次の順で判定する。

1. 回数の上限に達していれば止める。
1. 本文を再送できなければ止める(`NotReplayable`。sdk-runtime の `body` closure のように作り直せる場合は `replayable` で上書きする)。
2. 判定を上書きするヘッダーを見る。
3. 状態コードまたは失敗の種類を分類し、メソッドの規則と照らす。
4. サーバーが指定した待ち時間を読み、上限と比べる。Retry-After: 0 を「すぐ再送」とするか「指定なし」とするかは `zero_means_backoff` で選ぶ(requesto と今の sdk-runtime は前者、Stainless は後者)。上書きヘッダーが true でも、この上限判定は通る(openai と同じ順序)。
5. 待ち時間の指定がなければ backoff で決める。
6. 残り時間を超える待ちなら止める。

部品の扱い:

- `@http.is_idempotent`(idempotency-key に対応済み)と `HttpError::is_unsent` はそのまま使う。
- HTTP 日付形式の Retry-After を読めるよう、`now` を渡す。今の sdk-runtime は渡しておらず、日付形式を読み落としている。
- `Proxy(status)` は、その status が規則に一致したときだけ再送する。今の挙動を引き継ぐ。
- 乱数は外から受け取るので、wasm-gc でも動き、テストで値を固定できる。
- backoff は Double の `pow` を使わず、Int64 の整数演算で、上限に達したらそこで止める。
- `gaato/http` に置くひな形は `never()` だけ。それ以外の既定値は各層が持つ。

### `@http/sync.Timer`

```moonbit
pub(open) trait Timer {
  async fn within(Self, Int, async () -> Unit noraise) -> Bool noraise
}
```

前例は `Gate` と同じ「実行環境が外から差し込む部品」である。MoonBit の trait のメソッドは型引数を取れない見込みなので、総称型を使わない形にした。結果は呼び出し側が closure の外の `Ref` に書き出す。http-async が `ClockTimer`(`with_timeout_opt` を使う)で実装する。

### sdk-runtime 0.7.0(互換性を壊す変更)

**再送の方針**

- `RetryPolicy { rule }`。ひな形は次の 4 つ。
  - `conservative()`: 今の挙動。既定
  - `stainless(cap~)`
  - `none()`
  - `from_rule`
- `Backoff` は `gaato/http/retry` に移し、sdk-runtime からは re-export する。
- `RetryDecider` は `fn decide(Self, SdkError, RetryContext) -> Decision` に変える。`RetryContext` には bucket・request・attempt・random・now・remaining を入れる。
- `SdkError::outcome()` で `Outcome` に変換する。

**`Client` の変更**

- 呼び出しごとの `accept?` フックを足す。試行ループの中で応答を検査して、再送できるエラーに変えられる。GitHub GraphQL の 200 応答に使う。
- `Timeouts { timer, attempt_ms?, total_ms? }` を足す。
  - 1 回の試行は `timer.within(min(attempt, remaining))` で包む。
  - 全体の期限は、再送前の待ちと `Budget` で効かせる。
  - リミッターの `acquire`/`release` は包まない。対になっていることと `errdefer` を壊さないためである。

**`WindowLimiter` に足す任意の引数**

- `pace? : (String) -> Pace`: `Pace { group, min_interval_ms }`。純粋な関数で、gate のキーにも使う。
- `server_key? : (String, @http.Headers) -> String?`: 応答ヘッダーから、状態を記録するキーを読み替える。`alias` は MoonBit の予約語なので、この名前にした。
- `scope? : (Int, @http.Headers) -> LimitScope`: `Bucket` / `Global` / `Shared` / `Ignore`。既存の `global_block` は、これの薄い包みとして残す。
- 別名(aliases)と `next_admit_at` は `sweep_states` で掃除する。RESOURCE_BOUNDS.md に 2 行足す。

## SDK ごとの目標(出典は behavior/ にある)

| SDK | 再送 | 待ち時間 | 時間制限 | その他 |
|---|---|---|---|---|
| openai | `stainless(StopAbove(120000))`: 2 回。408/409/429/500–599 を全メソッドで再送。送った後の失敗も全メソッドで再送。`x-should-retry` に従う。`retry-after-ms`→`retry-after` の順に読む | 0.5 s→8 s、0.75〜1.0 倍。Retry-After が 120 s を超えたら再送しない | 600 s(timer を渡したときだけ) | — |
| anthropic | `stainless(NoCap)`。中身は openai と同じ | Retry-After に上限なしで従う | 600 s | 529 も再送するようになる |
| github | `conservative` で再送 3 回。5xx はべき等なものだけ | 二次制限は Retry-After、なければ `60 s << n`。一般の上限は無視し、残り時間と回数で抑える | — | GraphQL の 200 に乗る `RATE_LIMITED` と二次制限を `accept` で再送する。"Something went wrong" は mutation 以外だけ再送。バケットは core / core:write / graphql / search / core:notifications。`pace` は書き込みと graphql が 1 s、search が 2 s、notifications が 3 s。`server_key` は `x-ratelimit-resource`。利用者が渡した `gate` で直列化する |
| discord | 429 は全メソッドで再送(本文の `retry_after` + 1 ms)。502 は全メソッドで再送。500–599 と送った後の失敗はべき等なものだけ再送。`nonce` + `enforce_nonce` 付きのメッセージ作成はべき等として扱う | 本文の値を優先し、上限なし | `Timeouts` を使い、`AttemptDeadline` は削除 | JSON の本文も scope もない 429 は即座に失敗させる。401 で止める。`server_key` は `x-ratelimit-bucket` と主要パラメーター。scope が shared の 429 では止めない。不正リクエスト(401/403/429)を observer で数える |
| requesto | 公開 API は変えず、中身を `RetryRule` に載せ替える(Req 寄りの既定値はそのまま) | 今のまま | 今のまま | 既存のテストを、挙動が変わっていないことの確認に使う |

一次情報の要点:

- **Stainless**([openai-python@6eaa90e](https://github.com/openai/openai-python/blob/6eaa90ee20b40bbe84a5b1a5031d7cf672c7d368/src/openai/_base_client.py#L899-L936)、[anthropic-sdk-python@bcd55fe](https://github.com/anthropics/anthropic-sdk-python/blob/bcd55fe1d3f0f1240765f8cef04295b67337f55a/src/anthropic/_base_client.py#L929-L957))
  - `_should_retry` にメソッドの判定はない。
  - openai は `MAX_RETRY_AFTER_DELAY = 2 * 60` を超える Retry-After では `_should_retry` が `False` を返し、再送しない。anthropic は `retry_after > 0` ならいくらでも待つ。
  - 既定の時間制限はどちらも `Timeout(600, connect=5.0)`。
- **octokit**([plugin-retry@d6e06bd](https://github.com/octokit/plugin-retry.js/blob/d6e06bd8c68b34abcf1e4d24b647f74027788352/src/error-request.ts#L20-L24)、[plugin-throttling@eb4215e](https://github.com/octokit/plugin-throttling.js/blob/eb4215edcd97f20ade800b18d964bf798e0d70b7/src/wrap-request.ts#L25-L52)、[octokit.js@bc34dea](https://github.com/octokit/octokit.js/blob/bc34deaf357486594c41f167c05921d16e6aabe9/src/octokit.ts#L43-L44))
  - `doNotRetry` に入っていない 400 以上はすべて、待ち時間 `(n+1)^2` 秒で再送する。Retry-After は見ない。
  - 書き込みと GraphQL は 1 s、search は 2 s の間隔をあける。
  - レート制限による再送は 1 回だけ。
- **docs.github.com**
  - "Otherwise, wait for at least one minute before retrying."
  - "wait for an exponentially increasing amount of time between retries"
  - "you should make requests serially instead of concurrently"
  - GraphQL のレート制限超過は "the response status will still be `200`"
- **Discord docs**
  - 502 は "Wait a bit and retry."
  - 不正リクエストは "10,000 per 10 minutes … 401, 403, or 429"
  - `X-RateLimit-Bucket` は "It's recommended to use this header as a unique identifier"
  - `enforce_nonce` は "that message will be returned and no new message will be created"

## 段階

publish は取り消せないので、P1〜P4 の版上げの前にはそのつど確認する。spec-watch が openai/anthropic/github を自動で版上げするため、S3〜S5 は main に置かず、jj の bookmark `retry-core` に積んで P2 でまとめて入れる。

| 段 | 内容 | publish |
|---|---|---|
| S0 | このメモ、new-sdk.md、behavior/ | — |
| S1 | 着手前に言語の制約を確かめる(trait のメソッドが型引数を取れるか、`pub using` で enum の構成子まで出せるか、noraise の async closure を引数に取れるか)。そのうえで `gaato/http/retry` と `sync.Timer` を作る | **P1: http 0.5.0** |
| S2 | http-async を http 0.5.0 に追従させ、`ClockTimer` を足す | **P1: http-async 0.5.0** |
| S3 | sdk-runtime: RetryPolicy、RetryContext、accept、Timeouts | — |
| S4 | WindowLimiter: pace、server_key、scope | — |
| S5 | openai/anthropic を stainless と timer に移す。github の規則、pace、server_key、accept、二次制限 | **P2: sdk-runtime 0.7.0 / openai 0.6.0 / anthropic 0.11.0 / github 0.17.0** |
| S6 | discord.mbt を新しい core と limiter に載せる。`AttemptDeadline` を削除。不正リクエストを数える | **P3: discord 0.12.0** |
| S7 | requesto を core に載せる | **P4: requesto 0.2.1(mbti が変われば 0.3.0)** |
| S8 | 下流の追従: nekosama、gaato、discord-cli、docs-bot、kbbi | 必要なものだけ |

## 利用者から見える挙動の変化(CHANGELOG の `Migration:` に書く)

- **openai/anthropic**
  - POST を 5xx・409・送った後の時間切れで再送するようになる。生成が重複し、そのぶん費用がかかることがある。
  - anthropic は長い Retry-After にも従うので、`total_ms` の設定を勧める。
  - openai は、Retry-After が 120 s を超えたら再送しない。
  - README に書くこと: `AsyncTransport` の既定の時間制限は 30 s なので、そのままでは公式 SDK の 600 s にはならない。
- **sdk-runtime**
  - `Backoff` の形が変わる(`factor` がなくなり、`jitter` が enum になる)。
  - `RetryPolicy` のフィールドと `RetryDecider` の引数が変わる。
  - HTTP 日付形式の Retry-After を読むようになる。
- **github**
  - 再送が 3 回になる。
  - 書き込みと GraphQL の間隔を 1 s あけるので、連続した書き込みは遅くなる。
  - GraphQL の 200 に乗るレート制限を再送するようになる。
- **discord**
  - 502 を POST でも再送する。べき等なメソッドは 5xx でも再送する。
  - JSON のない 429 と 401 は即座に失敗する。
  - 試行の時間制限に 0 以下を指定したときのエラーの phase が変わる。

範囲外: `@http.Middleware` をどうするか、HTTP/2、kbbi と profile README の requesto への移行。
