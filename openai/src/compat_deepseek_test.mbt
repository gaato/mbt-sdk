// Constructed from DeepSeek docs, 2026-11-15; not captured live.
// https://api-docs.deepseek.com/api/create-chat-completion
// https://api-docs.deepseek.com/api/list-models
// https://api-docs.deepseek.com/api/create-response
// https://api-docs.deepseek.com/guides/thinking_mode

///|
test "DeepSeek chat, reasoning, keepalive stream, models and Responses fixtures" {
  let base = "https://api.deepseek.com"
  let chat : Json = {
    "id": "c",
    "object": "chat.completion",
    "created": 1,
    "model": "fixture-model",
    "choices": [
      {
        "index": 0,
        "message": {
          "role": "assistant",
          "content": "hello",
          "reasoning_content": "think",
        },
        "finish_reason": "insufficient_system_resource",
      },
    ],
  }
  compat_chat(
    base,
    chat,
    Some("think"),
    @openai.Unknown("insufficient_system_resource"),
  )
  compat_stream(
    base,
    [
      compat_chunk({ "reasoning_content": "think" }),
      compat_chunk({ "content": "hello" }, finish="stop"),
      compat_usage_chunk(),
    ],
    [
      @openai.ReasoningDelta("think"),
      @openai.Delta("hello"),
      @openai.Finished(@openai.Stop),
      @openai.Usage({ input_tokens: 2, output_tokens: 3, total_tokens: 5, }),
    ],
  )
  compat_models(
    base,
    {
      "object": "list",
      "data": [
        { "id": "fixture-model", "object": "model", "owned_by": "deepseek" },
      ],
    },
    None,
  )
  compat_responses(base)
}

///|
test "DeepSeek assistant tool call retains reasoning on the next request" {
  @driver.run_sync(() => {
    let fixture : Json = {
      "id": "c",
      "object": "chat.completion",
      "created": 1,
      "model": "fixture-model",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": null,
            "reasoning_content": "look up",
            "tool_calls": [
              {
                "id": "call",
                "type": "function",
                "function": { "name": "lookup", "arguments": "{}" },
              },
            ],
          },
          "finish_reason": "tool_calls",
        },
      ],
    }
    let backend = @testing.BackendStub::new()
      .expect(_ => true, compat_canned(fixture))
      .expect(_ => true, compat_canned(fixture))
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
      base_url="https://api.deepseek.com",
    )
    let first = api.chat_completion(compat_request()).unwrap()
    api
    .chat_completion(
      @openai.ChatRequest::new(model="fixture-model", messages=[
        @openai.ChatMessage::user("hello"),
        @openai.ChatMessage::assistant_tool_calls(
          first.tool_calls,
          reasoning_content?=first.reasoning_content,
        ),
        @openai.ChatMessage::tool(tool_call_id="call", content="done"),
      ]),
    )
    .unwrap()
    |> ignore
    let sent : Json = @json.parse(@utf8.decode(backend.sent()[1].body.unwrap()))
    guard sent
      is {
        "messages": [
          _,
          { "reasoning_content": "look up", "tool_calls": [_, ..], .. },
          { "tool_call_id": "call", .. },
        ],
        ..
      } else {
      fail("assistant reasoning was lost")
    }
    backend.verify()
  })
}
