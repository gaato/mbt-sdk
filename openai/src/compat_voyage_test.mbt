///|
// Adapted from the Voyage text embeddings reference, 2026-11-18.
// https://docs.voyageai.com/reference/embeddings-api
test "Voyage embeddings send provider options and decode total-only usage" {
  @driver.run_sync(() => {
    let base_url = "https://api.voyageai.com/v1"
    // The reference's two vectors are shortened for this fixture.
    let raw : Json = {
      "object": "list",
      "data": [
        {
          "object": "embedding",
          "embedding": [-0.016709786, 0.026996311],
          "index": 0,
        },
        {
          "object": "embedding",
          "embedding": [0.003613521, 0.026428301],
          "index": 1,
        },
      ],
      "model": "voyage-4-large",
      "usage": { "total_tokens": 8 },
    }
    let backend = @testing.BackendStub::new().expect(
      request => request.url == base_url + "/embeddings",
      compat_canned(raw),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
      base_url~,
    )
    let result = api
      .create_embeddings(
        @openai.EmbeddingRequest::new(
          model="voyage-4-large",
          input=["Sample text 1", "Sample text 2"],
          extra={ "input_type": "query", "output_dimension": 256 },
        ),
      )
      .unwrap()
    let sent = backend.sent()[0]
    assert_eq(sent.request.meth, @http.Post)
    assert_eq(sent.request.headers.get("authorization"), Some("Bearer fixture"))
    assert_eq(
      sent.request.headers.get("content-type"),
      Some("application/json"),
    )
    assert_eq(@json.parse(@utf8.decode(sent.body.unwrap())), {
      "input": ["Sample text 1", "Sample text 2"],
      "model": "voyage-4-large",
      "input_type": "query",
      "output_dimension": 256,
    })
    assert_eq(result, {
      data: [
        { index: 0, embedding: [-0.016709786, 0.026996311], },
        { index: 1, embedding: [0.003613521, 0.026428301], },
      ],
      model: "voyage-4-large",
      prompt_tokens: None,
      total_tokens: Some(8),
    })
    backend.verify()
  })
}

///|
// Constructed from the Voyage output_dtype schema, 2026-11-18.
// https://docs.voyageai.com/reference/embeddings-api
test "Voyage int8 embeddings decode JSON integer arrays" {
  @driver.run_sync(() => {
    let base_url = "https://api.voyageai.com/v1"
    let backend = @testing.BackendStub::new().expect(
      request => request.url == base_url + "/embeddings",
      compat_canned({
        "object": "list",
        "data": [
          { "object": "embedding", "embedding": [-128, 0, 127], "index": 0 },
        ],
        "model": "voyage-4-lite",
        "usage": { "total_tokens": 1 },
      }),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
      base_url~,
    )
    let request = @openai.EmbeddingRequest::new(
      model="voyage-4-lite",
      input=["hello"],
      extra={ "output_dtype": "int8" },
    )
    let result = api.create_embeddings(request).unwrap()
    assert_eq(result.data, [{ index: 0, embedding: [-128.0, 0.0, 127.0], }])
    assert_eq(@json.parse(@utf8.decode(backend.sent()[0].body.unwrap())), {
      "input": ["hello"],
      "model": "voyage-4-lite",
      "output_dtype": "int8",
    })
    backend.verify()
  })
}

///|
test "embedding extra rejects base64 before I/O" {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new()
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
    )
    let request = @openai.EmbeddingRequest::new(model="m", input=["hi"], extra={
      "encoding_format": "base64",
    })
    guard api.create_embeddings(request) is Err(@openai.Validation(message)) else {
      fail("expected a validation failure for base64 embeddings")
    }
    assert_true(message.contains("base64"))
    assert_eq(backend.sent().length(), 0)
    backend.verify()
  })
}

///|
test "embedding extra rejects typed keys even when optional fields are omitted" {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new()
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
    )
    for key in ["model", "input", "dimensions", "user"] {
      let extra = Map::from_array([(key, Json::null())])
      let request = @openai.EmbeddingRequest::new(
        model="m",
        input=["hi"],
        extra~,
      )
      guard api.create_embeddings(request) is Err(@openai.Validation(message)) else {
        fail("expected a validation failure for extra key " + key)
      }
      assert_eq(message, "extra parameter collides with known key: " + key)
    }
    assert_eq(backend.sent().length(), 0)
    backend.verify()
  })
}

///|
// Constructed from the Voyage 4XX schema, 2026-11-18.
// https://docs.voyageai.com/reference/embeddings-api.md
test "Voyage HTTP errors map string detail to a message and preserve the raw response" {
  @driver.run_sync(() => {
    let headers = @http.Headers::of([("x-request-id", "fixture")])
    let body = b"{ \"detail\": \"Invalid output dimension\" }"
    let backend = @testing.BackendStub::new()
      .expect(_ => true, @testing.Canned::bytes(400, headers~, body~))
      .expect(_ => true, compat_canned({ "detail": ["invalid"] }, status=400))
      .expect(_ => true, @testing.Canned::bytes(200, body~))
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
    )
    let request = @openai.EmbeddingRequest::new(model="m", input=["hi"])
    let failure = api.create_embeddings(request).unwrap_err()
    guard failure is @openai.Api(head, error, body=actual) else {
      fail("expected a typed API failure for string detail")
    }
    assert_eq(head.status, 400)
    assert_eq(head.headers, headers)
    assert_eq(actual, body)
    assert_eq(error, {
      message: "Invalid output dimension",
      type_: None,
      param: None,
      code: None,
    })
    assert_eq(@openai.api_error(failure), Some(error))
    let status_failure = @openai.Response(@client.UnexpectedStatus(head, body~))
    assert_eq(@openai.api_error(status_failure), Some(error))

    let malformed = api.create_embeddings(request).unwrap_err()
    assert_true(malformed is @openai.Response(@client.UnexpectedStatus(_, ..)))
    assert_eq(@openai.api_error(malformed), None)
    let success_status = api.create_embeddings(request).unwrap_err()
    assert_true(
      success_status is @openai.Response(@client.Deserialization(_, ..)),
    )
    backend.verify()
  })
}
