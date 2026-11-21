# moonbit-sdks

[MoonBit](https://www.moonbitlang.com/) 向けの API SDK と、Codex app-server のクライアントです。固定した上流の API 記述から公開の語彙を生成し、小さな表層で各社に固有の再試行・ストリーミング・ページ送り・エラーの解釈を足しています。どの SDK も非公式で、各社とは関係ありません。

[English](README.md)

<!-- BEGIN sdks: modules -->
| モジュール | 用途 | 依存 |
|---|---|---|
| [gaato/openai](openai/README.md) | モデル、埋め込み、Responses と Chat Completions | mttp_core |
| [gaato/anthropic](anthropic/README.md) | Messages、トークン数の計算、Models、ツール、ストリーミング | mttp_core |
| [gaato/github](github/README.md) | 生成した REST API、ページ送り、GraphQL | mttp_core |
| gaato/codex-protocol | 生成した型付きの Codex の呼び出しとイベント(未公開) | mttp_core/jsonkit |
| [gaato/jina](jina/README.md) | 生成した API の語彙(未公開) | mttp_core |
| [gaato/replicate](replicate/README.md) | 生成した API の語彙(未公開) | mttp_core |
| [gaato/gemini](gemini/README.md) | Gemini API: 生成、ストリーミング、埋め込み、ファイル、キャッシュしたコンテキスト | mttp_core |
| [gaato/cloudflare_dns](cloudflare_dns/README.md) | Cloudflare DNS: ゾーン、レコード、一括変更、BIND の取り込みと書き出し | mttp_core |
| gaato/jsonrpc | どこでも動く JSON-RPC のメッセージと NDJSON の区切り | core |
| gaato/jsonrpc-async | 双方向の接続と native の子プロセス | jsonrpc, core/async |
| [gaato/codex-app-server](codex-app-server/README.md) | 初期化済みのセッション、型付きのイベントとハンドラー | protocol, jsonrpc-async, core/async |
<!-- END sdks: modules -->

公開済みの HTTP の SDK は mooncakes にあり、表には未公開のモジュールを示しています。JSON-RPC と Codex のモジュールは未公開です。HTTP の基盤は [mttp](https://github.com/gaato/mttp) にあります。gaato/mttp_core が語彙・Backend・クライアントの方針を、gaato/mttp がアプリの足す I/O を受け持ちます。SDK のモジュールは実行環境を import しません。

アプリは gaato/mttp の `@mttp.backend()`・`@mttp.clock()`・`@mttp.timer()` を SDK に渡します。接続を再利用し応答を展開するネットワークと、時間制限に要る時刻です。SDK の失敗は Result の値で返り、TransportError とコールバックの例外は送出されます。バッファーする本文の既定の上限は 64 MiB、SSE のイベントは 16 MiB です。各モジュールの README に、コンパイルを確かめた使用例と、再試行・時間制限のふるまいがあります。

## 開発

SDK の登録・生成・ゲートの手順は英語版の [Development](README.md#development) にあります。

Apache-2.0 です。
