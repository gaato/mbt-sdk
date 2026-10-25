///|
async test "model pagination follows last_id and collects every item" {
  bounded(() => {
    let transport = @mock.FakeBackend::new()
    for
      (id, more, path) in [
        ("m1", true, "/v1/models?limit=1&lifecycle%5B%5D=active"),
        ("m2", false, "/v1/models?after_id=m1&limit=1&lifecycle%5B%5D=active"),
      ] {
      let body =
        $|{"data":[{"type":"model","id":"\{id}","display_name":"Model","created_at":"2026-04-01T00:00:00Z","lifecycle":"active","capabilities":null,"deprecated_at":null,"line":null,"max_input_tokens":null,"max_tokens":null,"retires_at":null}],"has_more":\{more},"first_id":"\{id}","last_id":"\{id}"}
      transport.expect("GET", path, json_response(body))
    }
    let client = @anthropic_sdk.Anthropic::new(
      api_key="test-key",
      transport,
      @mock.FakeClock::new(),
    )
    let models = client
      .paginate_models(limit=1, lifecycle=[Active])
      .collect(max=10)
    assert_eq(models.map(model => model.id), ["m1", "m2"])
    assert_true(transport.sent()[1].url.contains("after_id=m1"))
    transport.assert_complete()
  })
}

///|
async test "empty model pages and missing last_id end pagination" {
  bounded(() => {
    for has_more in [false, true] {
      let transport = @mock.FakeBackend::new()
      let body =
        $|{"data":[],"has_more":\{has_more},"first_id":null,"last_id":null}
      transport.expect("GET", "/v1/models", json_response(body))
      let client = @anthropic_sdk.Anthropic::new(
        api_key="test-key",
        transport,
        @mock.FakeClock::new(),
      )
      let pages = client.paginate_models()
      assert_eq(pages.collect(max=10).length(), 0)
      assert_true(pages.next_page() is None)
      assert_eq(transport.sent().length(), 1)
      transport.assert_complete()
    }
  })
}
