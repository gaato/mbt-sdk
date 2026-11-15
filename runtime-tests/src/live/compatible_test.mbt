///|
// Opt-in only. Model presets are a dated convenience, not compatibility evidence.
// See docs/live-tests.md for overrides, regions, endpoints and costs.
async fn compatible_live(
  prefix : String,
  default_base : String,
  default_model : String,
  models~ : Bool,
  responses~ : Bool,
  embedding_model? : String,
) -> Unit {
  bounded(() => {
    guard credential(prefix + "_API_KEY", prefix) is Some(key) else { return }
    let model = optional_setting(prefix + "_MODEL").unwrap_or(default_model)
    let base_url = optional_setting(prefix + "_BASE_URL").unwrap_or(
      default_base,
    )
    let api = @openai_sdk.OpenAI::new(
      api_key=key,
      live_transport(),
      @adapter.AsyncClock::new(),
      base_url~,
      retry=@runtime.RetryPolicy::none(),
      timeout_ms=45000,
    )
    if models {
      ignore(expect(api.list_models()))
    }
    let request = @openai_sdk.ChatRequest::new(
      model~,
      messages=[@openai_sdk.ChatMessage::user("Say hello.")],
      max_tokens=16,
    )
    ignore(expect(api.chat_completion(request)))
    // Decode success only: no assertions about generated text or token counts.
    ignore(expect(api.stream_chat_completion(request, _ => ())))
    let tool = @openai_sdk.ToolDef::new(name="echo", parameters={
      "type": "object",
      "properties": { "value": { "type": "string" } },
      "required": ["value"],
    })
    let user = @openai_sdk.ChatMessage::user("Call echo with value hello.")
    let reply = expect(
      api.chat_completion(
        @openai_sdk.ChatRequest::new(
          model~,
          messages=[user],
          tools=[tool],
          max_tokens=128,
        ),
      ),
    )
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
        expect(
          api.chat_completion(
            @openai_sdk.ChatRequest::new(
              model~,
              messages~,
              tools=[tool],
              max_tokens=16,
            ),
          ),
        ),
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
      ignore(expect(api.create_response(request)))
      ignore(expect(api.stream_response(request, _ => ())))
    }
    let selected_embedding = match
      optional_setting(prefix + "_EMBEDDING_MODEL") {
      Some(model) => Some(model)
      None => embedding_model
    }
    if selected_embedding is Some(model) {
      ignore(
        expect(
          api.create_embeddings(
            @openai_sdk.EmbeddingRequest::new(model~, input=["hello"]),
          ),
        ),
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
async test "live DashScope compatible decoding" {
  compatible_live(
    "DASHSCOPE",
    "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
    "qwen3.8",
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
