///|
async test "secondary limits retry GET and POST with server or fallback delays" {
  bounded(() => {
    for http_method in ["GET", "POST"] {
      for header in [true, false] {
        let transport = @mock.FakeTransport::new()
        let headers = if header {
          @http.Headers::from_array([("retry-after", "3")])
        } else {
          @http.Headers::new()
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
async test "plain forbidden, retry count, and fallback delay cap stop retries" {
  bounded(() => {
    for
      (body, retries, count, waits) in [
        ("{\"message\":\"Forbidden\"}", 2, 1, []),
        ("{\"message\":\"secondary rate limit\"}", 0, 1, []),
        ("{\"message\":\"secondary rate limit\"}", 1, 2, [60000]),
        ("{\"message\":\"secondary rate limit\"}", 2, 2, [60000]),
      ] {
      let transport = @mock.FakeTransport::new()
      for _ in 0..<count {
        transport.expect("GET", "/test", json_response(body, status=403))
      }
      let clock = @mock.FakeClock::new()
      let gh = @github_sdk.GitHub::new(transport, clock, limiter=no_limiter(), retry={
        ..@runtime.RetryPolicy::default(),
        max_retries: retries,
      })
      try gh.send(@http.Request::get("/test")) catch {
        error => assert_eq(error.status(), Some(403))
      } noraise {
        _ => fail("403 must fail after retries stop")
      }
      assert_eq(clock.slept(), waits)
      assert_eq(transport.sent().length(), count)
      transport.assert_complete()
    }
  })
}
