///|
async test "secondary limits retry GET and POST with server or fallback delays" {
  bounded(() => {
    for http_method in ["GET", "POST"] {
      for header in [true, false] {
        let transport = @mock.FakeBackend::new()
        let headers = if header {
          @http.Headers::of([("retry-after", "3")])
        } else {
          @http.Headers::empty()
        }
        transport.expect(
          http_method,
          "/test",
          json_response(
            "{\"message\":\"You have exceeded a secondary rate limit\"}",
            status=403,
            headers~,
          ),
        )
        transport.expect(http_method, "/test", json_response("{}"))
        let clock = @mock.FakeClock::new()
        let gh = @github_sdk.GitHub::new(transport, clock, limiter=no_limiter())
        let request = if http_method == "GET" {
          @http.Request::get("/test")
        } else {
          @http.Request::post("/test")
        }
        ignore(gh.send(request))
        assert_eq(clock.slept(), [if header { 3000 } else { 60000 }])
        assert_eq(transport.sent().length(), 2)
        transport.assert_complete()
      }
    }
  })
}

///|
async test "plain forbidden and the retry count stop retries; the fallback doubles past the cap" {
  bounded(() => {
    for
      (body, retries, count, waits) in [
        ("{\"message\":\"Forbidden\"}", 2, 1, []),
        ("{\"message\":\"secondary rate limit\"}", 0, 1, []),
        ("{\"message\":\"secondary rate limit\"}", 1, 2, [60000]),
        // The doubled wait is not held to the policy's 60 s Retry-After cap.
        ("{\"message\":\"secondary rate limit\"}", 2, 3, [60000, 120000]),
        (
          "{\"message\":\"secondary rate limit\"}",
          3,
          4,
          [60000, 120000, 240000],
        ),
      ] {
      let transport = @mock.FakeBackend::new()
      for _ in 0..<count {
        transport.expect("GET", "/test", json_response(body, status=403))
      }
      let clock = @mock.FakeClock::new()
      let gh = @github_sdk.GitHub::new(
        transport,
        clock,
        limiter=no_limiter(),
        retry=@runtime.RetryPolicy::default().with_max_retries(retries),
      )
      try gh.send(@http.Request::get("/test")) catch {
        error => assert_eq(@runtime.status_of(error), Some(403))
      } noraise {
        _ => fail("403 must fail after retries stop")
      }
      assert_eq(clock.slept(), waits)
      assert_eq(transport.sent().length(), count)
      transport.assert_complete()
    }
  })
}

///|
/// Asserts each wait lies within `conservative()`'s backoff for its retry:
/// 500 ms doubling, spread by ±20 %.
fn assert_conservative_backoff(slept : Array[Int32]) -> Unit raise {
  for i, wait in slept {
    let full = 500 * (1 << i)
    assert_true(
      wait >= full * 4 / 5 && wait <= full * 6 / 5,
      msg="wait \{i}: \{wait}",
    )
  }
}

///|
async test "a 502 is retried three times for GET and not at all for POST" {
  bounded(() => {
    let transport = @mock.FakeBackend::new()
    for _ in 0..<4 {
      transport.expect(
        "GET",
        "/repos/o/r",
        json_response("{\"message\":\"Server Error\"}", status=502),
      )
    }
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(transport, clock, limiter=no_limiter())
    try gh.send(@http.Request::get("/repos/o/r")) catch {
      error => assert_eq(@runtime.status_of(error), Some(502))
    } noraise {
      _ => fail("the fourth 502 must be raised")
    }
    assert_eq(clock.slept().length(), 3)
    assert_conservative_backoff(clock.slept())
    transport.assert_complete()

    // GitHub has no idempotency key: a resent POST could open a second issue.
    let writes = @mock.FakeBackend::new()
    writes.expect(
      "POST",
      "/repos/o/r/issues",
      json_response("{\"message\":\"Server Error\"}", status=502),
    )
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(writes, clock, limiter=no_limiter())
    try gh.send(@http.Request::post("/repos/o/r/issues")) catch {
      error => assert_eq(@runtime.status_of(error), Some(502))
    } noraise {
      _ => fail("a POST 502 must be raised")
    }
    assert_eq(clock.slept(), [])
    writes.assert_complete()
  })
}

///|
async test "a secondary limit without retry-after waits a minute, then two" {
  bounded(() => {
    let transport = @mock.FakeBackend::new()
    for _ in 0..<2 {
      transport.expect(
        "POST",
        "/repos/o/r/labels",
        json_response(
          "{\"message\":\"You have exceeded a secondary rate limit.\"}",
          status=403,
        ),
      )
    }
    transport.expect("POST", "/repos/o/r/labels", json_response("{}"))
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(transport, clock, limiter=no_limiter())
    ignore(gh.send(@http.Request::post("/repos/o/r/labels")))
    assert_eq(clock.slept(), [60000, 120000])
    transport.assert_complete()
  })
}

///|
async test "a primary limit waits until a second past the reset, once" {
  bounded(() => {
    let exhausted = (reset : Int32) => {
      json_response(
        "{\"message\":\"API rate limit exceeded for user ID 1.\"}",
        status=403,
        headers=rate_limit_headers(0, reset),
      )
    }
    let transport = @mock.FakeBackend::new()
    transport.expect("GET", "/repos/o/r", exhausted(100))
    transport.expect("GET", "/repos/o/r", exhausted(200))
    let clock = @mock.FakeClock::new()
    // The default limiter records the exhausted window too; by the time the
    // retry leaves, it has reset, so nothing waits twice.
    let gh = @github_sdk.GitHub::new(transport, clock, token="ghp_test")
    try gh.send(@http.Request::get("/repos/o/r")) catch {
      error => assert_eq(@runtime.status_of(error), Some(403))
    } noraise {
      _ => fail("a second primary limit must be raised")
    }
    assert_eq(clock.slept(), [101000])
    transport.assert_complete()

    let recovering = @mock.FakeBackend::new()
    recovering.expect("POST", "/repos/o/r/labels", exhausted(10))
    recovering.expect("POST", "/repos/o/r/labels", json_response("{}"))
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(recovering, clock, limiter=no_limiter())
    ignore(gh.send(@http.Request::post("/repos/o/r/labels")))
    assert_eq(clock.slept(), [11000])
    recovering.assert_complete()
  })
}

///|
async test "a transient graphql failure is retried for a query, not a mutation" {
  bounded(() => {
    let transient =
      #|{"data":null,"errors":[{"message":"Something went wrong while executing your query. Please include `0400:3E2B` when reporting this issue."}]}
    let transport = @mock.FakeBackend::new()
    transport.expect(
      "POST",
      "https://api.github.com/graphql",
      json_response(transient),
    )
    transport.expect(
      "POST",
      "https://api.github.com/graphql",
      json_response("{\"data\":{\"viewer\":{\"login\":\"gaato\"}}}"),
    )
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(transport, clock, limiter=no_limiter())
    assert_eq(gh.graphql(query="query { viewer { login } }"), {
      "viewer": { "login": "gaato" },
    })
    assert_eq(clock.slept().length(), 1)
    assert_conservative_backoff(clock.slept())
    transport.assert_complete()

    let mutation = @mock.FakeBackend::new()
    mutation.expect(
      "POST",
      "https://api.github.com/graphql",
      json_response(transient),
    )
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(mutation, clock, limiter=no_limiter())
    try
      gh.graphql(
        query="mutation { addStar(input: {starrableId: \"x\"}) { clientMutationId } }",
      )
    catch {
      @github_sdk.GraphqlFailure(_, ..) as error =>
        assert_true(@github_sdk.graphql_errors(error) is Some([_]))
      error => fail("expected Decode: " + @debug.to_string(error))
    } noraise {
      _ => fail("a mutation's failure must be raised")
    }
    assert_eq(clock.slept(), [])
    mutation.assert_complete()

    // graphql_response returns a mutation's failed envelope as before.
    let kept = @mock.FakeBackend::new()
    kept.expect(
      "POST",
      "https://api.github.com/graphql",
      json_response(transient),
    )
    let gh = @github_sdk.GitHub::new(
      kept,
      @mock.FakeClock::new(),
      limiter=no_limiter(),
    )
    guard gh.graphql_response(query="mutation { a }") is Object(fields) else {
      fail("expected the envelope")
    }
    assert_true(fields.get("errors") is Some(_))
    kept.assert_complete()
  })
}

///|
async test "a secondary limit reported in a graphql 200 is waited out" {
  bounded(() => {
    let transport = @mock.FakeBackend::new()
    transport.expect(
      "POST",
      "https://api.github.com/graphql",
      json_response(
        "{\"errors\":[{\"message\":\"You have exceeded a secondary rate limit.\"}]}",
        headers=@http.Headers::of([("retry-after", "5")]),
      ),
    )
    transport.expect(
      "POST",
      "https://api.github.com/graphql",
      json_response("{\"data\":{\"ok\":true}}"),
    )
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(transport, clock, limiter=no_limiter())
    assert_eq(gh.graphql(query="mutation { a }"), { "ok": true })
    assert_eq(clock.slept(), [5000])
    transport.assert_complete()
  })
}

///|
async test "writes, graphql, notifications and searches are spaced; reads are not" {
  bounded(() => {
    for
      case in [
        ("GET", "/repos/o/r", []),
        ("POST", "/repos/o/r/labels", [1000]),
        ("PATCH", "/repos/o/r", [1000]),
        ("POST", "/repos/o/r/issues", [3000]),
        ("GET", "/search/issues?q=x", [2000]),
        ("POST", "https://api.github.com/graphql", [1000]),
      ] {
      let (http_method, url, waits) = case
      let transport = @mock.FakeBackend::new()
      transport.expect(http_method, url, json_response("{}"))
      transport.expect(http_method, url, json_response("{}"))
      let clock = @mock.FakeClock::new()
      let gh = @github_sdk.GitHub::new(transport, clock, token="ghp_test")
      let request = @http.Request::new(@http.Method::parse(http_method), url)
      ignore(gh.send(request))
      ignore(gh.send(request))
      assert_eq((url, clock.slept()), (url, waits))
      transport.assert_complete()
    }

    // A notification-sending write holds the next plain write for 3 s; a
    // plain write holds the next notification-sending one for 1 s.
    let transport = @mock.FakeBackend::new()
    transport.expect("POST", "/repos/o/r/issues", json_response("{}"))
    transport.expect("POST", "/repos/o/r/labels", json_response("{}"))
    transport.expect("POST", "/repos/o/r/issues", json_response("{}"))
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(transport, clock, token="ghp_test")
    ignore(gh.send(@http.Request::post("/repos/o/r/issues")))
    ignore(gh.send(@http.Request::post("/repos/o/r/labels")))
    ignore(gh.send(@http.Request::post("/repos/o/r/issues")))
    assert_eq(clock.slept(), [3000, 1000])
    transport.assert_complete()
  })
}

///|
async test "a write shares the core window it names in x-ratelimit-resource" {
  bounded(() => {
    let core = (remaining : Int32, reset : Int32) => {
      let headers = rate_limit_headers(remaining, reset)
      headers.set("x-ratelimit-resource", "core")
    }
    let transport = @mock.FakeBackend::new()
    transport.expect(
      "POST",
      "/repos/o/r/labels",
      json_response("{}", headers=core(0, 60)),
    )
    transport.expect(
      "GET",
      "/repos/o/r",
      json_response("{}", headers=core(4999, 3600)),
    )
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(transport, clock, token="ghp_test")
    ignore(gh.send(@http.Request::post("/repos/o/r/labels")))
    // The write spent core's last request, so the read waits for its reset.
    ignore(gh.send(@http.Request::get("/repos/o/r")))
    assert_eq(clock.slept(), [60000])
    transport.assert_complete()
  })
}

///|
/// A `@sync.Gate` that counts its acquisitions and releases.
priv struct CountingGate {
  log : Array[String]
}

///|
impl @sync.Gate for CountingGate with fn acquire(self) {
  self.log.push("acquire")
}

///|
impl @sync.Gate for CountingGate with fn release(self) {
  self.log.push("release")
}

///|
async test "the caller's gate holds each paced group across a request" {
  bounded(() => {
    let log = []
    let groups = []
    let transport = @mock.FakeBackend::new()
    transport.expect("POST", "/repos/o/r/labels", json_response("{}"))
    transport.expect("GET", "/repos/o/r", json_response("{}"))
    let gh = @github_sdk.GitHub::new(
      transport,
      @mock.FakeClock::new(),
      token="ghp_test",
      gate=() => {
        groups.push(groups.length())
        CountingGate::{ log, }
      },
    )
    ignore(gh.send(@http.Request::post("/repos/o/r/labels")))
    ignore(gh.send(@http.Request::get("/repos/o/r")))
    // One gate per group (write, then core), each held for its request.
    assert_eq(groups.length(), 2)
    assert_eq(log, ["acquire", "release", "acquire", "release"])
    transport.assert_complete()
  })
}
