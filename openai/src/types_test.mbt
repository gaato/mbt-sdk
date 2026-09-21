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
