// Constructed from docs text, 2026-11-15; never captured live.
// https://openrouter.ai/docs/api-reference/errors
// https://docs.z.ai/api-reference/api-code
// https://help.aliyun.com/en/model-studio/error-code
// https://developers.openai.com/api/docs/guides/error-codes

///|
test "non-transient 429 codes stop buffered and streaming requests without a wait" {
  @driver.run_sync(() => {
    for
      code in [
        "1113", "1308", "1310", "insufficient_quota", "insufficient_balance", "account_disabled",
        "Throttling.AllocationQuota", "AllocationQuota.FreeTierOnly", "credit_balance_exhausted",
        "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded",
      ] {
      for streaming in [false, true] {
        let backend = @testing.BackendStub::new().expect(
          _ => true,
          compat_canned(
            { "error": { "message": "quota exhausted", "code": code } },
            status=429,
          ),
        )
        let clock = @mock.FakeClock::new()
        let api = @openai.OpenAI::new(api_key="fixture", backend, clock)
        let failure = if streaming {
          api
          .stream_chat_completion(compat_request(), _ => {
            fail("no callbacks on 429")
          })
          .unwrap_err()
        } else {
          api.chat_completion(compat_request()).unwrap_err()
        }
        assert_eq(@openai.api_error(failure).unwrap().code, Some(code))
        assert_eq(backend.sent().length(), 1)
        assert_eq(clock.slept(), [])
        backend.verify()
      }
    }
  })
}

///|
test "quota classification handles sparse numeric bodies and overrides retry-true on custom clients" {
  @driver.run_sync(() => {
    for
      error in [
        ({ "code": 1113 } : Json),
        { "code": "1308" },
        { "type": "insufficient_quota" },
      ] {
      let backend = @testing.BackendStub::new().expect(
        _ => true,
        @testing.Canned::bytes(
          429,
          headers=@http.Headers::of([("x-should-retry", "true")]),
          body=@utf8.encode(({ "error": error } : Json).stringify()),
        ),
      )
      let clock = @mock.FakeClock::new()
      let api = @openai.OpenAI::from_client(
        @client.Client::new(
          backend,
          clock,
          base_url="https://fixture.invalid",
          retry=@client.RetryPolicy::conservative(),
        ),
      )
      assert_true(api.list_models() is Err(_))
      assert_eq(clock.slept(), [])
      assert_eq(backend.sent().length(), 1)
      backend.verify()
    }
  })
}

///|
test "transient and unknown 429 bodies retain the configured retry decision" {
  @driver.run_sync(() => {
    for
      error in [
        ({ "message": "rate limited", "code": "1302" } : Json),
        { "message": "overloaded", "code": "1305" },
        { "message": "rate limited", "code": "Throttling.RateQuota" },
        { "message": "rate limited", "code": 429 },
        {
          "message": "slow down",
          "code": "slow_down",
          "type": "rate_limit_error",
        },
        { "message": "unknown", "code": "future" },
        { "message": "quota exhausted", "code": "unknown" },
      ] {
      let backend = @testing.BackendStub::new()
        .expect(_ => true, compat_canned({ "error": error }, status=429))
        .expect(_ => true, compat_canned({ "data": [] }))
      let clock = @mock.FakeClock::new()
      let api = @openai.OpenAI::new(api_key="fixture", backend, clock)
      assert_eq(api.list_models().unwrap(), [])
      assert_eq(backend.sent().length(), 2)
      assert_eq(clock.slept().length(), 1)
      backend.verify()
    }
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      compat_canned(
        { "error": { "message": "rate limited", "code": "1302" } },
        status=429,
      ),
    )
    let clock = @mock.FakeClock::new()
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      clock,
      retry=@client.RetryPolicy::none(),
    )
    assert_true(api.list_models() is Err(_))
    assert_eq(clock.slept(), [])
    backend.verify()
  })
}

///|
// Constructed from the vendored Responses/ResponseError schemas, 2026-11-15:
// https://github.com/openai/openai-openapi/blob/manual_spec/openapi.yaml
test "HTTP 200 failed Responses retain structured results and match streamed failures" {
  @driver.run_sync(() => {
    let raw = compat_response()
    guard raw is Object(fields) else { fail("fixture must be an object") }
    fields["status"] = "failed"
    fields["error"] = { "code": "server_error", "message": "generation failed" }
    let event : Json = { "type": "response.failed", "response": raw }
    let backend = @testing.BackendStub::new()
      .expect(_ => true, compat_canned(raw))
      .expect(
        _ => true,
        @testing.Canned::bytes(
          200,
          body=@utf8.encode("data: " + event.stringify() + "\n\n"),
        ),
      )
    let clock = @mock.FakeClock::new()
    let api = @openai.OpenAI::new(api_key="fixture", backend, clock)
    let request = @openai.ResponseRequest::new(
      model="fixture-model",
      input="hi",
    )
    let response = match api.create_response(request) {
      Ok(response) => response
      Err(error) =>
        fail(
          "valid failed Responses must remain Ok: " + @debug.to_string(error),
        )
    }
    assert_eq(response.status, @openai.Failed)
    assert_eq(response.id, "r")
    assert_eq(response.model, "fixture-model")
    assert_eq(response.output_text, "hello")
    assert_eq(
      response.usage,
      Some({ input_tokens: 2, output_tokens: 3, total_tokens: 5, }),
    )
    assert_eq(response.raw, raw)
    let events : Array[@openai.ResponseEvent] = []
    api.stream_response(request, event => events.push(event)).unwrap()
    assert_eq(events, [@openai.Failed(response)])
    assert_eq(backend.sent().length(), 2)
    assert_eq(clock.slept(), [])
    backend.verify()
  })
}

///|
test "buffered error classification uses each endpoint success decoder" {
  @driver.run_sync(() => {
    // Constructed valid success objects with an unknown extension field:
    // a field named error alone must not override a successfully decoded result.
    for
      (endpoint, raw) in [
        (
          "chat",
          (
            {
              "id": "c",
              "created": 1,
              "model": "m",
              "choices": [
                {
                  "index": 0,
                  "message": { "role": "assistant", "content": "hello" },
                  "finish_reason": "stop",
                },
              ],
            } : Json),
        ),
        ("models", { "data": [] }),
        ("retrieve", { "id": "m" }),
        (
          "embeddings",
          { "data": [], "model": "m", "usage": { "total_tokens": 0 } },
        ),
      ] {
      guard raw is Object(fields) else { fail("fixture must be an object") }
      fields["error"] = { "code": 503, "message": "extension" }
      let backend = @testing.BackendStub::new().expect(
        _ => true,
        compat_canned(raw),
      )
      let api = @openai.OpenAI::new(
        api_key="fixture",
        backend,
        @mock.FakeClock::new(),
      )
      let decoded = match endpoint {
        "chat" => api.chat_completion(compat_request()) is Ok(_)
        "models" => api.list_models() is Ok(_)
        "retrieve" => api.retrieve_model("m") is Ok(_)
        _ =>
          api.create_embeddings(
            @openai.EmbeddingRequest::new(model="m", input=["hi"]),
          )
          is Ok(_)
      }
      assert_true(decoded, msg=endpoint + " must use its success decoder")
      assert_eq(backend.sent().length(), 1)
      backend.verify()
    }
    // Responses-looking markers without the required response payload are not
    // sufficient to hide a real error envelope.
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      compat_canned({
        "id": "r",
        "object": "response",
        "error": { "code": 503, "message": "failed" },
      }),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
    )
    let failure = api
      .create_response(@openai.ResponseRequest::new(model="m", input="hi"))
      .unwrap_err()
    assert_eq(@openai.api_error(failure).unwrap().code, Some("503"))
    backend.verify()
  })
}

///|
test "OpenRouter numeric errors in HTTP 200 preserve head and diagnostic body for every buffered endpoint" {
  @driver.run_sync(() => {
    let raw : Json = {
      "error": {
        "code": 503,
        "message": "provider failed",
        "metadata": { "provider_name": "fixture" },
      },
    }
    for endpoint in ["chat", "responses", "models", "retrieve", "embeddings"] {
      let headers = @http.Headers::of([("x-request-id", "fixture")])
      let body = @utf8.encode(raw.stringify())
      let backend = @testing.BackendStub::new().expect(
        _ => true,
        @testing.Canned::bytes(200, headers~, body~),
      )
      let api = @openai.OpenAI::new(
        api_key="fixture",
        backend,
        @mock.FakeClock::new(),
      )
      let failure = match endpoint {
        "chat" => api.chat_completion(compat_request()).unwrap_err()
        "responses" =>
          api
          .create_response(@openai.ResponseRequest::new(model="m", input="hi"))
          .unwrap_err()
        "models" => api.list_models().unwrap_err()
        "retrieve" => api.retrieve_model("m").unwrap_err()
        _ =>
          api
          .create_embeddings(
            @openai.EmbeddingRequest::new(model="m", input=["hi"]),
          )
          .unwrap_err()
      }
      guard failure is @openai.Api(head, error, body=actual) else {
        fail("expected a typed API failure")
      }
      assert_eq(head.status, 200)
      assert_eq(head.headers, headers)
      assert_eq(actual, body)
      assert_eq(error.code, Some("503"))
      assert_eq(@openai.api_error(failure), Some(error))
      assert_eq(backend.sent().length(), 1)
      backend.verify()
    }
  })
}

///|
test "mid-stream errors stop delivery and never turn into Finished Unknown error" {
  @driver.run_sync(() => {
    for
      tail in [
        "data: {\"error\":{\"code\":503,\"message\":\"failed\"},\"choices\":[{\"finish_reason\":\"error\"}]}\n\n",
        "event: error\ndata: {\"code\":503,\"message\":\"failed\"}\n\n", "event: error\ndata: {\"error\":{\"code\":503,\"message\":\"failed\"}}\n\n",
      ] {
      let stream = "data: " +
        compat_chunk({ "content": "hello" }).stringify() +
        "\n\n" +
        tail +
        "data: not-json\n\n"
      let backend = @testing.BackendStub::new().expect(
        _ => true,
        @testing.Canned::bytes(200, body=@utf8.encode(stream)),
      )
      let clock = @mock.FakeClock::new()
      let api = @openai.OpenAI::new(api_key="fixture", backend, clock)
      let events : Array[@openai.ChatEvent] = []
      let failure = api
        .stream_chat_completion(compat_request(), event => events.push(event))
        .unwrap_err()
      assert_eq(events, [@openai.Delta("hello")])
      assert_eq(@openai.api_error(failure).unwrap().code, Some("503"))
      assert_eq(backend.sent().length(), 1)
      assert_eq(clock.slept(), [])
      backend.verify()
    }
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(
        200,
        body=b"event: error\ndata: {\"type\":\"error\",\"code\":\"server_error\",\"message\":\"failed\",\"param\":null}\n\ndata: not-json\n\n",
      ),
    )
    let api = @openai.OpenAI::new(
      api_key="fixture",
      backend,
      @mock.FakeClock::new(),
    )
    let failure = api
      .stream_response(@openai.ResponseRequest::new(model="m", input="hi"), _ => {
        fail("error must be a Result failure")
      })
      .unwrap_err()
    assert_eq(@openai.api_error(failure).unwrap().code, Some("server_error"))
    backend.verify()
  })
}

///|
test "numeric HTTP error codes normalize to strings without accepting unrelated shapes" {
  for
    (code, expected) in [
      (Json(402), Some("402")),
      (Json("1113"), Some("1113")),
      (Json::null(), None),
    ] {
    let body = @utf8.encode(
      ({ "error": { "message": "failed", "code": code } } : Json).stringify(),
    )
    let failure = @openai.Response(
      @client.UnexpectedStatus(
        { status: 402, headers: @http.Headers::empty(), },
        body~,
      ),
    )
    assert_eq(@openai.api_error(failure).unwrap().code, expected)
  }
}
