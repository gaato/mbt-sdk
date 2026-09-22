///|
test "constructors snapshot mutable inputs and OpenAI Debug redacts the key" {
  let inputs = ["first"]
  let embedding = @openai.EmbeddingRequest::new(
    model="text-embedding-3-small",
    input=inputs,
    dimensions=32,
    user="user-1",
  )
  inputs.push("later")
  assert_eq(embedding.input, ["first"])
  let extra : Map[String, Json] = { "metadata": { "source": "test" } }
  let response = @openai.ResponseRequest::new(
    model="gpt-4.1",
    input="hello",
    extra~,
  )
  extra["later"] = true
  assert_eq(response.extra, { "metadata": { "source": "test" } })
  let messages = [@openai.ChatMessage::user("hello")]
  let chat_extra : Map[String, Json] = { "seed": 1 }
  let chat = @openai.ChatRequest::new(
    model="gpt-4o-mini",
    messages~,
    extra=chat_extra,
  )
  messages.push(@openai.ChatMessage::assistant("later"))
  chat_extra["later"] = true
  assert_eq(chat.messages, [@openai.ChatMessage::user("hello")])
  assert_eq(chat.extra, { "seed": 1 })
  let assistant = @openai.ChatMessage::assistant_tool_calls([
    { id: "call_1", name: "lookup", arguments: "{}", },
  ])
  let tool_chat = @openai.ChatRequest::new(model="gpt-4o-mini", messages=[
    assistant,
  ])
  assistant.tool_calls
  .unwrap()
  .push({ id: "call_2", name: "later", arguments: "{}", })
  assert_eq(tool_chat.messages[0].tool_calls.unwrap().length(), 1)

  let key = "sk-key-that-must-not-leak"
  let client = @openai.OpenAI::new(
    api_key=key,
    @mock.FakeTransport::new(),
    @mock.FakeClock::new(),
  )
  let representation = @debug.Repr(client).to_string()
  assert_eq(representation, "OpenAI(<credentials redacted>)")
  assert_false(representation.contains(key))
}

///|
test "api_error extracts Status and RateLimited bodies only" {
  let body = b"{\"error\":{\"message\":\"bad key\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"invalid_api_key\"}}"
  let expected : @openai.ApiErrorBody = {
    message: "bad key",
    type_: Some("invalid_request_error"),
    param: None,
    code: Some("invalid_api_key"),
  }
  assert_eq(
    @openai.api_error(
      @runtime.Status(status=401, headers=@http.Headers::new(), body~),
    ),
    Some(expected),
  )
  assert_eq(
    @openai.api_error(
      @runtime.RateLimited(
        retry_after_ms=Some(1000),
        headers=@http.Headers::new(),
        body~,
      ),
    ),
    Some(expected),
  )
  assert_eq(@openai.api_error(@runtime.Decode(message="bad", body~)), None)
  assert_eq(
    @openai.api_error(
      @runtime.Status(
        status=400,
        headers=@http.Headers::new(),
        body=b"not json",
      ),
    ),
    None,
  )
}

///|
test "ToolCallAccumulator orders indexes and keeps the first id and name" {
  let accumulator = @openai.ToolCallAccumulator::new()
  accumulator.feed(index=1, id="call_1", name="second", arguments="{")
  accumulator.feed(index=0, arguments="{}")
  accumulator.feed(index=1, id="ignored", name="ignored", arguments="}")
  assert_eq(accumulator.finish(), [
    { id: "", name: "", arguments: "{}", },
    { id: "call_1", name: "second", arguments: "{}", },
  ])
}
