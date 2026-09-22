///|
test "constructors snapshot mutable inputs and Anthropic Debug redacts the key" {
  let blocks : Array[@anthropic.InputContentBlock] = [
    @anthropic.InputContentBlock::Unknown("image", {
      "type": "image",
      "source": { "data": "x" },
    }),
  ]
  let messages : Array[@anthropic.Message] = [
    { role: @anthropic.User, content: @anthropic.Blocks(blocks), },
  ]
  let stops = ["END"]
  let extra : Map[String, Json] = { "top_p": 0.5 }
  let request = @anthropic.MessageRequest::new(
    model="claude-opus-5",
    max_tokens=64,
    messages~,
    stop_sequences=stops,
    extra~,
  )
  blocks.push(
    @anthropic.InputContentBlock::Text(
      @gen.RequestTextBlock::new(text="later", type_="text"),
    ),
  )
  messages.push(@anthropic.Message::user("later"))
  stops.push("LATER")
  extra["later"] = true
  assert_eq(request.messages.length(), 1)
  guard request.messages[0].content is @anthropic.Blocks(saved) else {
    fail("expected blocks")
  }
  assert_eq(saved.length(), 1)
  assert_eq(request.stop_sequences, Some(["END"]))
  assert_eq(request.extra, { "top_p": 0.5 })

  let key = "anthropic-key-that-must-not-leak"
  let client = @anthropic.Anthropic::new(
    api_key=key,
    @mock.FakeTransport::new(),
    @mock.FakeClock::new(),
  )
  let representation = @debug.Repr(client).to_string()
  assert_eq(representation, "Anthropic(<credentials redacted>)")
  assert_false(representation.contains(key))
}

///|
test "message constructors, generated params and response text" {
  assert_eq(@anthropic.Message::user("question"), {
    role: @anthropic.User,
    content: @anthropic.Text("question"),
  })
  assert_eq(@anthropic.Message::assistant("answer"), {
    role: @anthropic.Assistant,
    content: @anthropic.Text("answer"),
  })
  let request = @anthropic.MessageRequest::new(
    model="claude-opus-5",
    max_tokens=8,
    messages=[@anthropic.Message::user("hi")],
    system="be brief",
  )
  let params = request.to_params()
  assert_eq(params.model, "claude-opus-5")
  assert_eq(params.stream, None)
  assert_eq(request.to_params(stream=true).stream, Some(true))
  assert_eq(
    params.system,
    Some(@gen.CreateMessageParamsSystem::Text("be brief")),
  )
  let message = @gen.Message::new(
    id="msg_1",
    model="claude-opus-5",
    content=[
      @gen.ContentBlock::Text(
        @gen.ResponseTextBlock::new(text="hello ", type_="text"),
      ),
    ],
    usage=@gen.Usage::new(input_tokens=3, output_tokens=4),
    stop_reason=@anthropic.StopReason::EndTurn,
  )
  let response : @anthropic.MessageResponse = {
    id: "msg_1",
    model: "claude-opus-5",
    role: @anthropic.Assistant,
    content: [
      @anthropic.Text("hello "),
      @anthropic.Thinking(thinking="hidden", signature="sig"),
      @anthropic.ToolUse(id="tool_1", name="lookup", input={ "q": "x" }),
      @anthropic.Text("world"),
    ],
    stop_reason: Some(@anthropic.StopReason::EndTurn),
    usage: message.usage,
    message,
    raw: null,
  }
  assert_eq(response.text(), "hello world")
  assert_eq(response.tool_uses(), [("tool_1", "lookup", { "q": "x" })])
}

///|
test "api_error extracts only valid status and rate-limit envelopes" {
  let body = b"{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"bad key\"},\"request_id\":\"req_1\"}"
  let expected : @anthropic.ApiErrorBody = {
    type_: "authentication_error",
    message: "bad key",
  }
  assert_eq(
    @anthropic.api_error(
      @runtime.Status(status=401, headers=@http.Headers::new(), body~),
    ),
    Some(expected),
  )
  assert_eq(
    @anthropic.api_error(
      @runtime.RateLimited(
        retry_after_ms=Some(1000),
        headers=@http.Headers::new(),
        body~,
      ),
    ),
    Some(expected),
  )
  for
    malformed in [
      b"{}", b"{\"type\":\"not_error\",\"error\":{\"type\":\"x\",\"message\":\"y\"}}",
      b"{\"type\":\"error\",\"error\":{\"message\":\"missing type\"}}",
    ] {
    assert_eq(
      @anthropic.api_error(
        @runtime.Status(
          status=400,
          headers=@http.Headers::new(),
          body=malformed,
        ),
      ),
      None,
    )
  }
  assert_eq(@anthropic.api_error(@runtime.Config("not an HTTP error")), None)
}
