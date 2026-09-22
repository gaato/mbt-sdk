# 設計メモ — `gaato/llm`(下書き。まだ作らない)

## 位置づけ

プロバイダのモジュール(`gaato/openai`、`gaato/anthropic`)は**ワイヤ上のプロトコル**ごとに分ける。OpenAI プロトコルは OpenRouter / Ollama / vLLM が、Anthropic Messages プロトコルは OpenRouter / Bedrock / Vertex が話すので、この境界はベンダーではなくプロトコルの境界として意味がある。モジュールは publish と依存の単位でもあるので、embeddings だけ欲しい人に別プロバイダの生成型(数千行)を持たせない。

「プロバイダをまたいで同じコードで呼びたい」「モデルのフォールバックを OpenAI ↔ Anthropic で切り替えたい」という需要は上の層で満たす。それが `gaato/llm`。

## 依存の向き

```
gaato/llm            共通の語彙(型と trait)だけ。依存は gaato/http と gaato/sdk-runtime
   ▲        ▲
gaato/openai  gaato/anthropic     それぞれが llm の trait を実装する(llm に依存する)
```

逆向き(`llm` が全プロバイダに依存)は、OpenAI しか使わない人に Anthropic を引き込ませるので採らない。`llm` は小さく、めったに変わらないものにする。

## 語彙(最小公倍数)

```moonbit
pub(all) enum Role { System; User; Assistant; Tool }
pub(all) struct ChatMessage { role : Role; content : String; name : String? }
pub(all) struct ChatRequest { model : String; messages : Array[ChatMessage]; max_tokens : Int?; temperature : Double?; extra : Map[String, Json] }
pub(all) struct Usage { input_tokens : Int; output_tokens : Int }
pub(all) enum FinishReason { Stop; Length; ToolCalls; ContentFilter; Unknown(String) }
pub(all) struct ChatResponse { text : String; finish : FinishReason?; usage : Usage?; raw : Json }
pub(all) enum ChatEvent { TextDelta(String); ReasoningDelta(String); ToolCallDelta(Json); Done(ChatResponse); Other(String, Json) }
pub(open) trait ChatProvider {
  async fn chat(Self, ChatRequest) -> ChatResponse raise @runtime.SdkError
  async fn stream(Self, ChatRequest, async (ChatEvent) -> Unit raise) -> Unit
}
```

- 共通化は必ず情報を落とす(reasoning ブロック、キャッシュ制御、ツール定義の方言、構造化出力)。`llm` は「便利層」と割り切り、`raw` と `extra` を必ず通し、細部が要る人はプロバイダのモジュールを直接使う。
- フォールバック(`Array[&ChatProvider]` を順に試す)と、モデル名 → プロバイダの表(`"anthropic/..."` → anthropic)は `llm` に置いてよい。ただし再試行の判断は `sdk-runtime` の `is_retryable` を使い、二重に再試行しない。

## いつ作るか

利用者が 1 人で、プロバイダをまたぐ具体的な用途が出ていない間は作らない。作る合図: (1) 実 API テストの「候補モデルを順に試す」ロジックをプロバイダ横断にしたくなったとき、(2) 2 本目の利用者(アプリ)が出たとき。先例: Elixir `req_llm`、`mizchi/llm`、`marianoguerra/llm`(いずれも一体型。`llm-mb` の `Dialect` trait は上の `ChatProvider` に近い)。
