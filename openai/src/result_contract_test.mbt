///|
test "transport effects retain identity instead of becoming SDK values" {
  @driver.run_sync(() => {
    let original = @http.TransportError(
      kind=Network,
      phase=Head,
      detail="reset",
    )
    let api = @openai.OpenAI::new(
      api_key="test",
      @client.from_fn((_, _) => raise original),
      @mock.FakeClock::new(),
      retry=@client.RetryPolicy::none(),
    )
    try {
      ignore(api.list_models())
      fail("transport failure became a value")
    } catch {
      @http.TransportError(..) as actual =>
        assert_true(physical_equal(original, actual))
      error => raise error
    }
  })
}

///|
test "validation is a value and callback decode exceptions remain effects" {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(
        200,
        body=b"data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n",
      ),
    )
    let api = @openai.OpenAI::new(
      api_key="test",
      backend,
      @mock.FakeClock::new(),
    )
    assert_true(
      api.chat_completion(
        @openai.ChatRequest::new(model="m", messages=[], extra={
          "model": "collision",
        }),
      )
      is Err(@openai.Validation(_)),
    )
    assert_eq(backend.sent().length(), 0)
    let original = @json.InvalidEof
    try {
      ignore(
        api.stream_chat_completion(
          @openai.ChatRequest::new(model="m", messages=[]),
          _ => raise original,
        ),
      )
      fail("callback exception became a value")
    } catch {
      @json.InvalidEof as actual =>
        assert_true(physical_equal(original, actual))
      error => raise error
    }
    assert_eq(backend.sent().length(), 1)
    backend.verify()
  })
}
