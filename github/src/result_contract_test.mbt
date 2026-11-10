///|
test "transport effects retain identity instead of becoming SDK values" {
  @driver.run_sync(() => {
    let original = @http.TransportError(
      kind=Network,
      phase=Head,
      detail="reset",
    )
    let api = @github.GitHub::new(
      @client.from_fn((_, _) => raise original),
      @mock.FakeClock::new(),
      retry=@client.RetryPolicy::none(),
      limiter=@client.NoLimiter::new(),
    )
    try {
      ignore(api.send(@http.Request::get("/")))
      fail("transport failure became a value")
    } catch {
      @http.TransportError(..) as actual =>
        assert_true(physical_equal(original, actual))
      error => raise error
    }
  })
}

///|
test "custom decoder exceptions retain identity and are never retried" {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(200),
    )
    let api = @github.GitHub::new(
      backend,
      @mock.FakeClock::new(),
      limiter=@client.NoLimiter::new(),
    )
    let original = @json.InvalidEof
    let decode : (_, _) -> Result[Unit, @client.ResponseFailure] raise = (_, _) => {
      raise original
    }
    try {
      ignore(api.call(@http.Request::get("/"), decode))
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
