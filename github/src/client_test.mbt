///|
test "mttp retries GraphQL rate limits with their real HTTP head" {
  @driver.run_sync(() => {
    let backend = @testing.BackendStub::new()
      .expect(
        _ => true,
        @testing.Canned::bytes(
          200,
          headers=@http.Headers::of([("x-ratelimit-reset", "1")]),
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
    let data = api.graphql(query="query { viewer { login } }").unwrap()
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
  @driver.run_sync(() => {
    let body = b"{\"errors\":[{\"message\":\"Something went wrong while executing your query\"}]}"
    let headers = @http.Headers::of([("x-request-id", "request-1")])
    let backend = @testing.BackendStub::new().expect(
      _ => true,
      @testing.Canned::bytes(200, headers~, body~),
    )
    let api = @github.GitHub::new(
      backend,
      @mock.FakeClock::new(),
      limiter=@client.NoLimiter::new(),
    )
    match api.graphql(query="mutation { change }") {
      Err(@github.GraphqlFailure(head, body=actual, ..)) => {
        assert_eq(head.status, 200)
        assert_eq(head.headers, headers)
        assert_eq(actual, body)
      }
      _ => fail("mutation error must be returned")
    }
    assert_eq(backend.sent().length(), 1)
    backend.verify()
  })
}

///|
test "mttp preserves partial GraphQL responses and decodes generated REST calls" {
  @driver.run_sync(() => {
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
    assert_eq(
      api.graphql_response(query="query { viewer { login } }").unwrap(),
      { "data": { "viewer": null }, "errors": [{ "message": "denied" }] },
    )
    let repo = api
      .call(@gen.repos_get_request("o", "r"), @gen.repos_get_decode)
      .unwrap()
    assert_eq(repo.full_name, "octocat/Hello-World")
    backend.verify()
  })
}

///|
test "downloads follow the 302 without the token unless redirect_limit is 0" {
  @driver.run_sync(() => {
    let start = "https://api.github.com/repos/gaato/moonbit-sdks/tarball/main"
    let location = "https://codeload.github.com/gaato/moonbit-sdks/legacy.tar.gz/main"
    let redirect = @testing.Canned::bytes(
      302,
      headers=@http.Headers::of([("location", location)]),
    )
    let backend = @testing.BackendStub::new()
      .expect(
        request => {
          request.url == start &&
          request.headers.get("authorization") == Some("Bearer secret")
        },
        redirect,
      )
      .expect(
        request => {
          request.url == location && !request.headers.contains("authorization")
        },
        @testing.Canned::bytes(200, body=b"archive"),
      )
      .expect(request => request.url == start, redirect)
    let api = @github.GitHub::new(
      backend,
      @mock.FakeClock::new(),
      token="secret",
      limiter=@client.NoLimiter::new(),
    )
    let request = @gen.repos_download_tarball_archive_request(
      "gaato", "moonbit-sdks", "main",
    )
    assert_eq(api.send(request).unwrap().body, b"archive")
    let held = api.send(request.attribute(@client.redirect_limit, 0))
    guard held is Err(@github.GitHubFailure::Http(failure)) else {
      fail("the 302 was followed")
    }
    assert_eq(failure.head().status, 302)
    assert_eq(failure.head().headers.get("location"), Some(location))
    backend.verify()
  })
}

///|
test "GitHub from_client strips and redacts authorization for REST and GraphQL" {
  let origin = "https://github.example"
  let other = "https://other.example/next"
  for graphql in [false, true] {
    let seen = []
    let backend = @client.from_fn((request, _) => {
      seen.push(request)
      if request.url.has_prefix(origin) {
        @http.Response::new(
          307,
          headers=@http.Headers::of([("location", other)]),
        )
      } else {
        @http.Response::new(200, body=Bytes(b"{\"data\":{}}"))
      }
    })
    let runtime = @client.Client::new(
      backend,
      @mock.FakeClock::new(),
      base_url=origin,
      headers=@http.Headers::of([("authorization", "Bearer fixture-token")]),
      redirect={ ..@client.RedirectConfig::default(), credential_headers: [], },
    )
    let sdk = @github.GitHub::from_client(
      runtime,
      graphql_url=origin + "/graphql",
    )
    @driver.run_sync(() => {
      if graphql {
        assert_true(sdk.graphql(query="{ viewer { login } }") is Ok(_))
      } else {
        assert_true(sdk.send(@http.Request::get("/rest")) is Ok(_))
      }
    })
    assert_eq(seen.length(), 2)
    assert_eq(
      seen[0].headers.get("authorization"),
      Some("Bearer fixture-token"),
    )
    assert_true(
      seen[0].attributes
      .get(@http.credential_headers)
      .unwrap_or([])
      .contains("authorization"),
    )
    assert_false(
      @client.request(seen[0])
      .response(@client.as_bytes())
      .to_curl()
      .contains("fixture-token"),
    )
    assert_eq(seen[1].url, other)
    assert_eq(seen[1].headers.get("authorization"), None)
  }
}

///|
test "GitHub rejects explicit header whitespace as validation before I/O" {
  let backend = @testing.BackendStub::new()
  let clock = @mock.FakeClock::new()
  let agent = @github.GitHub::new(backend, clock, user_agent="fixture\t")
  let version = @github.GitHub::new(backend, clock, api_version=" 2022-11-28")
  let token = @github.GitHub::new(backend, clock, token=" fixture")
  let sdk = @github.GitHub::new(backend, clock)
  let request = @http.Request::get("/rest")
  @driver.run_sync(() => {
    for invalid in [agent, version, token] {
      assert_true(
        invalid.send(request) is Err(@github.GitHubFailure::Validation(_)),
      )
      assert_true(
        invalid.graphql(query="{ viewer { login } }")
        is Err(@github.GitHubFailure::Validation(_)),
      )
    }
    assert_true(
      sdk.send(request.header("user-agent", " override"))
      is Err(@github.GitHubFailure::Validation(_)),
    )
  })
  assert_true(backend.sent().is_empty())
}

///|
test "GitHub propagates request validation raised by a response decoder" {
  let backend = @testing.BackendStub::new().expect(
    _ => true,
    @testing.Canned::bytes(200, body=b"{}"),
  )
  let sdk = @github.GitHub::new(backend, @mock.FakeClock::new())
  @driver.run_sync(() => {
    let nested = @http.Request::get("https://nested.example").header(
      "x-test", " invalid",
    )
    let outer : Result[Unit, @github.GitHubFailure] = sdk.call(
      @http.Request::get("/rest"),
      (_, _) => {
        nested.validate()
        Ok(())
      },
    ) catch {
      @http.TransportError(kind=Invalid, phase=Pool, ..) => return
      error => raise error
    }
    fail(
      "expected the nested request error to raise, got \{@debug.to_string(outer)}",
    )
  })
  backend.verify()
}

///|
priv struct NestedRequestBody {
  client : @client.Client
}

///|
impl @http.BodyStream for NestedRequestBody with fn read_some(self) {
  let request = @http.Request::get("https://nested.example").header(
    "x-test", " invalid",
  )
  ignore(
    self.client.send(@client.request(request).response(@client.as_bytes())),
  ) catch {
    @http.TransportError(..) as error => raise error
    _ => abort("unexpected nested request error")
  }
  None
}

///|
impl @http.BodyStream for NestedRequestBody with fn close(_) {
  ()
}

///|
test "GitHub propagates a nested request error raised while reading its response" {
  let clock = @mock.FakeClock::new()
  let nested_backend = @testing.BackendStub::new()
  let body = NestedRequestBody::{
    client: @client.Client::new(nested_backend, clock),
  }
  let backend = @client.from_fn((_, _) => {
    @http.Response::new(200, body=Stream(@http.StreamBody::new(body)))
  })
  let sdk = @github.GitHub::new(backend, clock)
  @driver.run_sync(() => {
    let outer = sdk.send(@http.Request::get("/rest")).map(reply => reply.status) catch {
        @http.TransportError(kind=Invalid, phase=Pool, ..) => return
        error => raise error
      }
    fail(
      "expected the nested request error to raise, got \{@debug.to_string(outer)}",
    )
  })
  assert_true(nested_backend.sent().is_empty())
}
