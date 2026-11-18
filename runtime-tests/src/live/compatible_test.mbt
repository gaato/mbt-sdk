///|
fn compatible_client(
  prefix : String,
  key : String,
  default_base : String,
) -> @openai_sdk.OpenAI {
  let base_url = optional_setting(prefix + "_BASE_URL").unwrap_or(default_base)
  @openai_sdk.OpenAI::new(
    api_key=key,
    live_transport(),
    @adapter.AsyncClock::new(),
    base_url~,
    retry=@runtime.RetryPolicy::none(),
    timeout_ms=45000,
  )
}

///|
// Opt-in only. See docs/live-tests.md for model overrides, endpoints and costs.
async fn compatible_live(
  prefix : String,
  default_base : String,
  default_model : String,
  models~ : Bool,
  responses~ : Bool,
  embedding_model? : String,
  chat_max_tokens~ : Int32 = 16,
  require_stream_event~ : Bool = false,
) -> Unit {
  bounded(() => {
    guard credential(prefix + "_API_KEY", prefix) is Some(key) else { return }
    let model = optional_setting(prefix + "_MODEL").unwrap_or(default_model)
    let api = compatible_client(prefix, key, default_base)
    if models {
      ignore(expect("list_models", () => api.list_models()))
    }
    let request = @openai_sdk.ChatRequest::new(
      model~,
      messages=[@openai_sdk.ChatMessage::user("Say hello.")],
      max_tokens=chat_max_tokens,
    )
    ignore(expect("chat_completion", () => api.chat_completion(request)))
    let mut decoded_event = false
    expect("stream_chat_completion", () => {
      api.stream_chat_completion(request, event => {
        if !(event is @openai_sdk.Other(_, _)) {
          decoded_event = true
        }
      })
    })
    if require_stream_event {
      assert_true(
        decoded_event,
        msg="stream_chat_completion delivered no decoded protocol events",
      )
    }
    let tool = @openai_sdk.ToolDef::new(name="echo", parameters={
      "type": "object",
      "properties": { "value": { "type": "string" } },
      "required": ["value"],
    })
    let user = @openai_sdk.ChatMessage::user("Call echo with value hello.")
    let reply = expect("chat_completion (tools)", () => {
      api.chat_completion(
        @openai_sdk.ChatRequest::new(
          model~,
          messages=[user],
          tools=[tool],
          max_tokens=chat_max_tokens.max(128),
        ),
      )
    })
    if !reply.tool_calls.is_empty() {
      let messages = [
        user,
        @openai_sdk.ChatMessage::assistant_tool_calls(
          reply.tool_calls,
          content=reply.text,
          reasoning_content?=reply.reasoning_content,
        ),
      ]
      for call in reply.tool_calls {
        let result = @openai_sdk.ChatMessage::tool(
          tool_call_id=call.id,
          content="hello",
        )
        messages.push({ ..result, name: Some(call.name), })
      }
      ignore(
        expect("chat_completion (tool result)", () => {
          api.chat_completion(
            @openai_sdk.ChatRequest::new(
              model~,
              messages~,
              tools=[tool],
              max_tokens=chat_max_tokens,
            ),
          )
        }),
      )
    } else {
      println("skip: " + prefix + " tool round trip: model returned no calls")
    }
    if responses {
      let request = @openai_sdk.ResponseRequest::new(
        model~,
        input="Say hello.",
        max_output_tokens=16,
      )
      ignore(expect("create_response", () => api.create_response(request)))
      expect("stream_response", () => api.stream_response(request, _ => ()))
    }
    let selected_embedding = match
      optional_setting(prefix + "_EMBEDDING_MODEL") {
      Some(model) => Some(model)
      None => embedding_model
    }
    if selected_embedding is Some(model) {
      ignore(
        expect("create_embeddings", () => {
          api.create_embeddings(
            @openai_sdk.EmbeddingRequest::new(model~, input=["hello"]),
          )
        }),
      )
    }
  })
}

///|
async test "live DeepSeek compatible decoding" {
  compatible_live(
    "DEEPSEEK",
    "https://api.deepseek.com",
    "deepseek-flash",
    models=true,
    responses=true,
  )
}

///|
async test "live Gemini compatible decoding" {
  compatible_live(
    "GEMINI",
    "https://generativelanguage.googleapis.com/v1beta/openai",
    "gemini-2.5-flash",
    models=true,
    responses=false,
    embedding_model="gemini-embedding-001",
    // Give thinking and visible output room within the same token budget.
    chat_max_tokens=4096,
    require_stream_event=true,
  )
}

///|
async test "live Voyage compatible embeddings" {
  bounded(() => {
    guard credential("VOYAGE_API_KEY", "Voyage") is Some(key) else { return }
    let model = optional_setting("VOYAGE_EMBEDDING_MODEL").unwrap_or(
      "voyage-4-lite",
    )
    let api = compatible_client("VOYAGE", key, "https://api.voyageai.com/v1")
    let request = @openai_sdk.EmbeddingRequest::new(model~, input=["hello"], extra={
      "input_type": "query",
    })
    let result = expect("create_embeddings", () => {
      api.create_embeddings(request)
    })
    guard result.data is [{ index: 0, embedding, }] && !embedding.is_empty() else {
      fail("expected one nonempty Voyage embedding at index zero")
    }
  })
}

///|
async test "live DashScope compatible decoding" {
  compatible_live(
    "DASHSCOPE",
    "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    "qwen3.8-flash",
    models=false,
    responses=true,
    embedding_model="text-embedding-v4",
  )
}

///|
async test "live Zhipu compatible decoding" {
  compatible_live(
    "ZAI",
    "https://open.bigmodel.cn/api/paas/v4",
    "glm-4.7-flash",
    models=false,
    responses=false,
    embedding_model="embedding-3",
  )
}

///|
async test "live Moonshot compatible decoding" {
  compatible_live(
    "MOONSHOT",
    "https://api.moonshot.ai/v1",
    "kimi-k3.1-pro",
    models=true,
    responses=true,
  )
}
