# 設計メモ — M8: 3 本目の SDK `gaato/github`(REST API 全面生成)

目的は 2 つ。(1) `gaato/http` + `gaato/sdk-runtime` が LLM API に寄っていないかを、REST らしい相手で確かめる。(2) 生成器を「API の一部を選んで通す」のではなく「ドキュメントを丸ごと通す」使い方で動かし、それが MoonBit で成立するかを実測する。

## なぜ 3 本目が LLM ではなく REST なのか

既存の consumer は `gaato/openai`(148 op 中 5 op を生成)と `gaato/anthropic`(244 op 中 4 op)で、どちらも「1 本の POST + SSE」に形が寄っている。その結果、`sdk-runtime` に置いた REST 向けの機能が一度も実利用されていなかった。

| 機能 | M7 までの利用者 |
|---|---|
| `Paginator` / `Page` | `runtime-tests` の単体テストのみ |
| `parse_link_next`(RFC 8288 `Link`) | 同上 |
| `WindowLimiter` + `rate_limit_headers` | 同上 |
| バケット指定つきの `Client::send` | openai / anthropic は固定バケット 1 個 |

「使われていない runtime 機能」は仕様が固まっているように見えて実際には固まっていない。GitHub REST API はこの 4 つをすべて素で要求する(`Link` ヘッダのページング、`x-ratelimit-*`、`/search/*` だけ別枠のクォータ、条件付きリクエストの 304)ので、3 本目の相手に選んだ。実際、`GitHub::paginator` が `Paginator` と `parse_link_next` の、`GitHub::new` の既定 limiter が `WindowLimiter` と `rate_limit_headers` の、最初の実利用者になっている。

first-party の OpenAPI があること(`github/rest-api-description`)も条件だった。生成器に通せない spec を相手にすると、このリポジトリが吸収したい「上流の変化」が overlay ではなく手書きに漏れる。

## スコープの決定と実測根拠

タグ単位に間引かず、**ドキュメント内の全 1,221 operation を生成する**。根拠は次の実測。

| 項目 | 値 |
|---|---:|
| operations / schemas | 1,221 / 988 |
| census diagnostics(素の spec、generator 修正後) | 76 |
| 〃 `fix.yaml` 適用後 | 65 |
| 〃 `fix.yaml` + `moonbit.yaml` 適用後 | **0** |
| `github/src/gen/types.mbt` | 168,626 行 |
| `github/src/gen/operations.mbt` | 40,169 行 |
| `github/src/gen/pkg.generated.mbti` | 43,403 行 |
| cold `moon -C github check --deny-warn`(P0 スパイク時の実測) | 2.6 秒 / ピーク RSS 527MB |

`moon check` の判定基準は「CI で許容できる時間」= 60 秒以内としていた(openai は 15.7k 行で 0.31 秒)。208k 行で 2.6 秒なので余裕があり、退避策として用意していた「package 分割」「362 op へのスコープ縮小」はどちらも不要だった。行数は多いが、MoonBit 側のボトルネックにはなっていない。

census が 99 → 76 に下がっているのは overlay ではなく generator 修正による。`Unknown` / `Custom` fallback constructor の名前衝突(13 件)と、`+1` / `-1` の variant 名が同じ名前に潰れる件(10 件)を `tools/gen` 側で直した。どちらも anthropic で一度 overlay を当てた問題の再発なので、overlay ではなく generator に置いた。残りの 76 件を overlay で処理した(`fix.yaml` が上流の不整合として 11 件、`moonbit.yaml` が MoonBit 側の判断として 65 件)。内訳と理由は `docs/census.md` に表で置いた。

## facade を薄くした判断

openai / anthropic は、生成型を安定した手書き facade 型へ写す(`*_from_generated`)。GitHub ではこれを**しない**。

- 1,221 op ぶんの手写しは、spec 追従のコストと釣り合わない。上流が動くたびに「生成型」と「手写し型」の 2 つを直すことになり、このリポジトリが避けたいはずの二重管理をそのまま持ち込む。
- LLM API の facade には、生の型を隠す実質的な価値があった(`MessageResponse::text()` のような畳み込み、provider 間の差の吸収)。REST の CRUD にはその畳み込みが無く、facade を挟んでも名前が変わるだけになる。

したがって生成パッケージ `gaato/github/gen` をそのまま公開型の語彙とし、facade は「送る・辿る・読む」だけを持つ。

代償は明示しておく。**公開型の名前と形が上流ドキュメントに直結する**ので、GitHub が schema 名やプロパティを変えれば `gaato/github` の公開 API もその形で変わる。`gaato/openai` のように SDK 側で互換層を張る余地が無い。これは意識的な取引で、「上流に追従し続けること」を「API の安定」より優先した結果である。0.1.0 で個別 op のラッパ(`gh.get_repo(...)` 等)を書かないのも同じ理由。

## 公開 API(契約)

配置は `github/`(module `gaato/github`、依存は `gaato/http` と `gaato/sdk-runtime` だけ)。`github/src/pkg.generated.mbti` の全量が以下で、これ以外は `gaato/github/gen` の生成物である。

```moonbit
pub struct GitHub                                   // priv client : @runtime.Client
pub fn GitHub::new(
  &@http.Transport, &@clock.Clock,
  token? : String,                                  // 省略時 NoAuth(公開リソースは無認証で読める)
  base_url? : String,                               // = "https://api.github.com"、GHES は .../api/v3
  api_version? : String,                            // = "2022-11-28" → x-github-api-version
  user_agent? : String,                             // = "gaato-mbt-sdk/0.1.0"(GitHub は User-Agent 必須)
  retry? : @runtime.RetryPolicy,
  limiter? : &@runtime.RateLimiter,                 // 既定は下記の WindowLimiter
) -> Self
pub fn GitHub::from_client(@runtime.Client) -> Self // GHES / プロキシ / テスト用の逃げ道
pub impl @debug.Debug for GitHub                    // 常に GitHub(<credentials redacted>)

pub async fn[T] GitHub::call(
  Self, @http.Request, (@http.Response) -> T raise @runtime.SdkError,
) -> T raise @runtime.SdkError
pub async fn GitHub::send(Self, @http.Request) -> @http.Response raise @runtime.SdkError
pub fn[T] GitHub::paginator(
  Self, @http.Request, (@http.Response) -> Array[T] raise @runtime.SdkError,
) -> @runtime.Paginator[T]

pub(all) struct ApiErrorBody {
  message : String; documentation_url : String?; status : String?; errors : Array[Json]?
} derive(Eq, @debug.Debug)
pub fn api_error(@runtime.SdkError) -> ApiErrorBody?
pub fn is_not_modified(@runtime.SdkError) -> Bool
pub fn is_secondary_rate_limit(@runtime.SdkError) -> Bool
```

規則:

- 既定ヘッダは `accept: application/vnd.github+json` / `x-github-api-version` / `user-agent` の 3 つだけ。`Client::prepare` は request 側のヘッダを既定より優先するので、op 固有の `accept`(`.diff` / `.patch` / `.sarif`)は呼び出し側が上書きできる。**生成 op は `accept` を一切立てない**(`repos_get_request(...).headers.length() == 0` を smoke test で固定)。
- `call` は生成 op の 2 つ組(`<op>_request` / `<op>_decode`)を 1 行で繋ぐだけ。デコードすべき本体が無い応答(204 / 304)と、JSON でない表現は `send` を使う。
- `paginator` の cursor は `Link` の `rel="next"` URL をそのまま入れる。`Client::prepare` は絶対 URL を素通しするので、2 ページ目以降を組み立て直す処理は facade に無い。`search_*` は `{items, total_count}` の封筒なので、`items` を返す decoder で包む必要がある。
- `ApiErrorBody.status` が `String?` なのは GitHub が `"404"` と文字列で書くため。数値で来ても同じ形に読む(互換プロキシ対策)。
- `Debug` は runtime 内部を辿らず、常に `GitHub(<credentials redacted>)` を返す。

## spec を `2022-11-28` に pin した理由

詳細は `github/spec/SOURCE.md`。要約すると、同じ 1,221 op を記述する 3 つの文書のうち:

- 無印 `api.github.com.yaml` は 2022-11-28 と**値の差分がゼロ**で、`x-github-breaking-changes` 注釈 1,095 箇所が乗るだけ。
- `2022-11-28` が今日 API が実際に返す形。これを vendor し、`X-GitHub-Api-Version` として送る。
- `2026-03-10` は将来版。ヘッダにその値を送っても現時点では旧挙動(`/rate_limit` に `rate` がある)が返るので、そこから生成すると型が wire とずれる。

`X-GitHub-Api-Version` はサーバからの保証ではない(GitHub は存在しないバージョン値でも 200 を返す)。あくまで自衛のピンとして送っている。vendor 形式に JSON ではなく YAML を選んだのは、261,041 行の行指向ファイルの方が `spec-watch.yml` の PR の diff が読めるため。

## rate limit、secondary limit、304

- **バケット**: GitHub は `/search/*` を他と別枠で計る(毎分 30 対 毎時 5,000)。同じ limiter バケットに入れると、search の狭い窓が core の残量を汚す。`rate_limit_bucket` はリクエスト URL のパスだけを見て `"search"` か `"core"` を返す。URL は生成 op が作った相対パスのこともあれば `Link` が書いた絶対 URL のこともあるので、scheme / authority と GHES の `/api/v3` マウントを剥がしてから判定する。
- **secondary rate limit**: 時間あたりクォータとは別の仕組みで、403 か 429 + `retry-after`(または本文の message)で来る。`x-ratelimit-remaining` は減らないので、どんな limiter も先回りできない。ここで `sdk-runtime` の `classify` に `SecondaryRateLimited` を足す選択肢はあったが、**足さなかった**。taxonomy は API 非依存で、「403 のうち一部は rate limit」は GitHub の運用上の約束であって HTTP の意味論ではない。runtime を GitHub に寄せると 4 本目で歪む。代わりに facade の述語 `is_secondary_rate_limit` が `Status(403)` と `RateLimited(429)` の両方を跨いで判定する。
- **304**: 条件付きリクエスト(`if-none-match` / `if-modified-since`)の成功は 304 で、runtime は非 2xx として `Status(304)` にする。これも正常系との区別は呼び出し側の文脈次第なので、`is_not_modified` という述語だけを提供して分類は変えない。304 はクォータに計上されない。

## テスト計画と実績

| 層 | 場所 | 件数 | 見るもの |
|---|---|---:|---|
| facade 同期 | `github/src/errors_test.mbt` / `call_wbtest.mbt` / `generated_smoke_test.mbt` | 13 | エラー本文のデコードと 3 つの述語、`Debug` の秘匿(7)、バケット選択・URL 正規化・既定ヘッダと上書き(4)、生成 op の method / path / query と spec example のデコード(2) |
| 非同期 | `runtime-tests/src/github/` | 11 | `FakeTransport` + `FakeClock`。既定ヘッダと認証、request ヘッダが既定に勝つこと、`Link` 3 ページの巡回、`x-ratelimit-remaining: 0` で limiter が待つこと、502 のリトライ、429 / 403+`retry-after` / 304 |
| live | `runtime-tests/src/live/` | 4 点 | 無認証の `repos/get`、`Link` 2 ページ以上、`x-ratelimit-*` の観測、`contents/{path}` に `docs/census.md` が通ること |

live の env 名は `MBT_SDK_GITHUB_TOKEN`(GitHub Actions が `GITHUB_TOKEN` を自動注入するので衝突を避ける)。live は gates に入れない。

multi-segment path parameter は live でしか壊れ方が見えないので、**live 側を「素直に失敗させる」形にした**。生成 URL が `/contents/docs/census.md` で終わらなければその場で validation failure にする。以前あった「generator がまだ `/` を percent-encode する既知の欠陥」という注記は、`x-moonbit-path-segments` が配線され `percent_encode_segments(` が生成物に 67 箇所出た時点で古くなったので消した。

## 既知の制約

- **raw `Json` に落ちた 43 箇所**(overlay 24 アクション)。分類と理由は `docs/census.md`。後から個別に型を付けられる形にしてあり、op のシグネチャは変わらない。
- **required かつ nullable なフィールドはキーの存在が必須**。生成される `decode_nullable_field` は「null は許すが欠如は許さない」ので、`null` を省いて返す中継プロキシの応答はデコードに失敗する。実例として `content-file` は `git_url` / `html_url` / `download_url` を required かつ nullable と宣言しており、テスト fixture もこの 3 キーを明示的に `null` で持つ必要がある。GitHub 本体は送るので実運用では問題にならないが、GHES 前段のプロキシで踏む可能性がある。
- **生成 op は `accept` を立てない**。diff / patch / sarif などの表現が要るときは呼び出し側が `.header("accept", ...)` を付ける。
- 個別 op のラッパは無い。`call` / `paginator` に生成 op の 2 つ組を渡す形が唯一の呼び出し方。
- 公開型が上流の schema 名と形に直結する(前述の取引)。

## 上流 spec の不具合 12 件

`github/overlays/fix.yaml` と `moonbit.yaml` の `description` が根拠。GitHub に issue を立てられる粒度でまとめる。★ は影響が大きいもの。

| # | 箇所 | 内容 |
|---:|---|---|
| 1 | `code-security-default-configurations.items.properties.default_for_new_repos` | 3 つの文字列値を `enum` に並べながら `type` を宣言していない。同じ schema の他の enum プロパティも、同名の `code-security-configuration` 側も `type: string` を持つ |
| 2 | `private-user.user_view_type` / `public-user.user_view_type` | `/user` 等の `oneOf` が `discriminator.propertyName: user_view_type` と `private` / `public` の mapping を宣言しているのに、当の property は制約なしの `string`。mapping を守る手段が文書内に無い |
| 3 ★ | `/repos/{owner}/{repo}/contents/{path}` の 200 の `discriminator` | `mapping` が値 `array` を `content-directory` に写すが、`content-directory` は `type: array` で、JSON 配列はプロパティを持てない。この分岐の payload は discriminator property を**原理的に**運べない |
| 4 ★ | `/repos/{owner}/{repo}/check-runs` POST の `discriminator` | `mapping` が無いので暗黙 mapping(component schema 名で候補を指す)にフォールバックするが、候補 2 つとも inline schema で名前が無い。永久に解決しない |
| 5 | check-run の作成 / 更新 request body | 全プロパティを持つ object schema の脇に `anyOf` / `oneOf` が付いている。union を素直にコンパイルする consumer は sibling の `properties` を捨てるため、`name` / `output` / `actions` などが静かに落ちる。branch が表現しているのは「`status` が `completed` なら `conclusion` が必須」という条件付き必須で、これは `conclusion` の description に散文で既に書いてある |
| 6 | `environment.protection_rules.items.anyOf[0..2].properties.type` | 3 分岐は optional プロパティの有無しか違わず、どの payload も 3 つすべてに validate するので `anyOf` が何も判別しない。分岐を決める値(`wait_timer` / `required_reviewers` / `branch_policy`)は `enum` ではなく `example` に置かれている |
| 7 | `issue-field-value.value.anyOf` | `[string, number, integer]`。JSON の integer はすべて `number` にも validate するので、3 番目の分岐は 2 番目が受けない値を 1 つも持たない |
| 8 | Pages 更新 body / campaigns body の分岐 | `required` に、その schema が宣言していないプロパティを挙げている(Pages の `public` は API から何年も前に消えている、campaigns の `secret_scanning_alerts`)。どちらの分岐も満たしようがない |
| 9 | `components.examples.full-repository.value` | `full-repository` は `has_discussions` を `required` に挙げているのに、同じ文書内の `repos/get` の 200 の example がそれを欠く。文書が自分自身と矛盾している(実 API は送る) |
| 10 | `integration.permissions` / `nullable-integration.permissions` | `additionalProperties: {type: string}` の脇に、まったく同じ型の named property が 5 つ(`issues` / `checks` / `metadata` / `contents` / `deployments`)。GitHub の権限は 40 個前後あり増え続けるので、この 5 つは構造ではなく例示 |
| 11 | agent-tasks の `creator`(`description: The entity who created this task`、5 箇所) | 分岐が 1 つだけの `oneOf`。1 分岐の union は分岐そのものと同じで、選ぶものが無い |
| 12 ★ | タグが sibling プロパティ側にある union 群 | `event.payload`(タグは `event.type`)、`secret-scanning-location.details`(`type`)、`artifacts[].data`(`artifacts[].type`)、`projects-v2-item-simple.content`(`content_type`)、`pull-request-merge-async-result.details`(`status`)。判別に必要な値が union の外にあるので、payload だけを見る decoder には手がかりが無い。**上流がこれを直せば raw `Json` が最も多く減る** |

いずれも `tools/apply_overlay.py` が zero-match / no-op を失敗として扱うので、GitHub が直した時点で overlay が落ちて気づける。
