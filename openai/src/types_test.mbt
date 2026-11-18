///|
test "constructors snapshot mutable inputs and OpenAI Debug redacts the key" {
  let inputs = ["first"]
  let embedding_extra : Map[String, Json] = { "input_type": "query" }
  let embedding = @openai.EmbeddingRequest::new(
    model="text-embedding-3-small",
    input=inputs,
    dimensions=32,
    user="user-1",
    extra=embedding_extra,
  )
  inputs.push("later")
  embedding_extra["input_type"] = "document"
  assert_eq(embedding.input, ["first"])
  assert_eq(embedding.extra, { "input_type": "query" })
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
  let google : Map[String, Json] = { "thought_signature": "original" }
  let tool_extra : Map[String, Json] = {
    "extra_content": { "google": Json::object(google) },
    "provider_extension": true,
  }
  let assistant = @openai.ChatMessage::assistant_tool_calls([
    { id: "call_1", name: "lookup", arguments: "{}", extra: tool_extra, },
  ])
  google["thought_signature"] = "modified call"
  tool_extra["provider_extension"] = false
  assert_eq(assistant.tool_calls.unwrap()[0].extra, {
    "extra_content": { "google": { "thought_signature": "original" } },
    "provider_extension": true,
  })
  let tool_chat = @openai.ChatRequest::new(model="gpt-4o-mini", messages=[
    assistant,
  ])
  assistant.tool_calls
  .unwrap()
  .push({ id: "call_2", name: "later", arguments: "{}", extra: {}, })
  let assistant_extra = assistant.tool_calls.unwrap()[0].extra
  guard assistant_extra
    is { "extra_content": { "google": Object(google), .. }, .. } else {
    fail("expected nested Google tool metadata")
  }
  google["thought_signature"] = "modified history"
  assistant_extra["provider_extension"] = false
  assert_eq(tool_chat.messages[0].tool_calls.unwrap().length(), 1)
  assert_eq(tool_chat.messages[0].tool_calls.unwrap()[0].extra, {
    "extra_content": { "google": { "thought_signature": "original" } },
    "provider_extension": true,
  })

  let key = "sk-key-that-must-not-leak"
  let client = @openai.OpenAI::new(
    api_key=key,
    @testing.BackendStub::new(),
    @mock.FakeClock::new(),
  )
  let representation = @debug.Repr(client).to_string()
  assert_eq(representation, "OpenAI(<credentials redacted>)")
  assert_false(representation.contains(key))
}

///|
test "request extras snapshot nested JSON objects and arrays" {
  let object : Map[String, Json] = { "key": "before" }
  let array : Array[Json] = [Json::object(object)]
  let extra : Map[String, Json] = { "provider_option": Json::array(array) }
  let chat = @openai.ChatRequest::new(model="m", messages=[], extra~)
  let embedding = @openai.EmbeddingRequest::new(model="m", input=["hi"], extra~)
  let response = @openai.ResponseRequest::new(model="m", input="hi", extra~)
  object["key"] = "after"
  array.push("added")
  for snapshot in [chat.extra, embedding.extra, response.extra] {
    assert_eq(snapshot, { "provider_option": [{ "key": "before" }] })
  }
}

///|
test "api_error extracts unexpected HTTP status bodies only" {
  let body = b"{\"error\":{\"message\":\"bad key\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"invalid_api_key\"}}"
  let expected : @openai.ApiErrorBody = {
    message: "bad key",
    type_: Some("invalid_request_error"),
    param: None,
    code: Some("invalid_api_key"),
  }
  assert_eq(
    @openai.api_error(
      @openai.Response(
        @client.UnexpectedStatus(
          { status: 401, headers: @http.Headers::empty(), },
          body~,
        ),
      ),
    ),
    Some(expected),
  )
  assert_eq(
    @openai.api_error(
      @openai.Response(
        @client.UnexpectedStatus(
          { status: 429, headers: @http.Headers::of([("retry-after", "1")]), },
          body~,
        ),
      ),
    ),
    Some(expected),
  )
  assert_eq(
    @openai.api_error(
      @openai.Response(
        @client.Deserialization(
          { status: 200, headers: @http.Headers::empty(), },
          message="bad",
          body~,
        ),
      ),
    ),
    None,
  )
  assert_eq(
    @openai.api_error(
      @openai.Response(
        @client.UnexpectedStatus(
          { status: 400, headers: @http.Headers::empty(), },
          body=b"not json",
        ),
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
    { id: "", name: "", arguments: "{}", extra: {}, },
    { id: "call_1", name: "second", arguments: "{}", extra: {}, },
  ])
}

///|
test "ToolCallAccumulator snapshots metadata on feed and finish" {
  let google : Map[String, Json] = { "thought_signature": "original" }
  let accumulator = @openai.ToolCallAccumulator::new()
  accumulator.feed(index=0, arguments="", extra={
    "extra_content": { "google": Json::object(google) },
  })
  google["thought_signature"] = "modified delta"
  let first = accumulator.finish()[0]
  assert_eq(first.extra, {
    "extra_content": { "google": { "thought_signature": "original" } },
  })
  guard first.extra is { "extra_content": { "google": Object(google), .. }, .. } else {
    fail("expected nested Google tool metadata")
  }
  google["thought_signature"] = "modified result"
  accumulator.feed(index=0, arguments="", extra={
    "extra_content": {
      "google": { "thought_signature": "later", "flag": true },
    },
  })
  assert_eq(accumulator.finish()[0].extra, {
    "extra_content": {
      "google": { "thought_signature": "original", "flag": true },
    },
  })
}
