///|
test "mttp retries GraphQL rate limits with their real HTTP head" {
  @testing.run_sync(() => {
    let backend = @testing.BackendStub::new()
      .expect(
        _ => true,
        @testing.Canned::bytes(
          200,
          headers=@model.Headers::of([("x-ratelimit-reset", "1")]),
          body=b"{\"errors\":[{\"type\":\"RATE_LIMITED\",\"message\":\"quota\"}]}",
        ),
      )
      .expect(
        request => request.url == "https://ghe.example/api/graphql",
        @testing.Canned::bytes(
          200,
          body=b"{\"data\":{\"viewer\":{\"login\":\"user\"}}}",
        ),
      )
    let clock = @mock.FakeClock::new()
    let api = @github.GitHub::new(
      backend,
      clock,
      token="secret",
      base_url="https://ghe.example/api/v3",
      limiter=@client.NoLimiter::new(),
    )
    let data = api.graphql(query="query { viewer { login } }")
    assert_eq(data, { "viewer": { "login": "user" } })
    assert_eq(clock.slept(), [2000])
    assert_eq(backend.sent()[0].body, backend.sent()[1].body)
    assert_eq(
      backend.sent()[0].request.headers.get("authorization"),
      Some("Bearer secret"),
    )
    backend.verify()
  })
}

///|
test "mttp does not retry a GraphQL mutation transient failure" {
  @testing.run_sync(() => {
    let body = b"{\"errors\":[{\"message\":\"Something went wrong while executing your query\"}]}"
    let headers = @model.Headers::of([("x-request-id", "request-1")])
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(200, headers~, body~),
    )
    let api = @github.GitHub::new(
      backend,
      @mock.FakeClock::new(),
      limiter=@client.NoLimiter::new(),
    )
    try api.graphql(query="mutation { change }") |> ignore catch {
      @github.GraphqlFailure(head, body=actual, ..) => {
        assert_eq(head.status, 200)
        assert_eq(head.headers, headers)
        assert_eq(actual, body)
      }
      error => fail(error.to_string())
    } noraise {
      _ => fail("mutation error must propagate")
    }
    assert_eq(backend.sent().length(), 1)
    backend.verify()
  })
}

///|
test "mttp preserves partial GraphQL responses and decodes generated REST calls" {
  @testing.run_sync(() => {
    let value = @json.parse(full_repository_example())
    guard value is Object(fields) else { fail("expected object") }
    // The upstream example omits this required field; match the spec overlay.
    fields["has_discussions"] = false
    let backend = @testing.BackendStub::new()
      .expect(
        _ => true,
        @testing.Canned::bytes(
          200,
          body=b"{\"data\":{\"viewer\":null},\"errors\":[{\"message\":\"denied\"}]}",
        ),
      )
      .expect(
        request => request.url == "https://api.github.com/repos/o/r",
        @testing.Canned::bytes(200, body=@utf8.encode(value.stringify())),
      )
    let api = @github.GitHub::new(
      backend,
      @mock.FakeClock::new(),
      limiter=@client.NoLimiter::new(),
    )
    assert_eq(api.graphql_response(query="query { viewer { login } }"), {
      "data": { "viewer": null },
      "errors": [{ "message": "denied" }],
    })
    let repo = api.call(@gen.repos_get_request("o", "r"), @gen.repos_get_decode)
    assert_eq(repo.full_name, "octocat/Hello-World")
    backend.verify()
  })
}
