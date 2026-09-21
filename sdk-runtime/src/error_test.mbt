///|
test "classification status retry table and preserved payloads" {
  for
    status in [
      199, 200, 204, 299, 301, 400, 401, 404, 408, 409, 429, 500, 502, 503, 504,
    ] {
    for retry in [None, Some("1.25")] {
      let headers = @http.Headers::new()
      if retry is Some(value) {
        headers.set("Retry-After", value)
      }
      let response : @http.Response = { status, headers, body: b"payload", }
      try @runtime.classify(response) catch {
        error => {
          assert_true(status < 200 || status > 299)
          assert_eq(error.status(), Some(status))
          assert_eq(
            error.is_retryable(),
            status is (408 | 409 | 429 | 500 | 502 | 503 | 504),
          )
          match error {
            @runtime.RateLimited(retry_after_ms~, headers=actual, body~) => {
              assert_eq(status, 429)
              assert_eq(retry_after_ms, retry.map(_ => 1250))
              assert_eq(actual, headers)
              assert_eq(body, response.body)
            }
            @runtime.Status(status=actual_status, headers=actual, body~) => {
              assert_eq(actual_status, status)
              assert_eq(actual, headers)
              assert_eq(body, response.body)
            }
            _ => fail("unexpected classification")
          }
        }
      } noraise {
        actual => {
          assert_true(status >= 200 && status <= 299)
          assert_eq(actual, response)
        }
      }
    }
  }
}

///|
test "non status errors and explicitly constructed statuses" {
  for
    (error, expected) in (
      [
        (@runtime.Transport(@http.Connect("offline")), true),
        (@runtime.Transport(@http.Timeout(12)), true),
        (@runtime.Transport(@http.Protocol("bad frame")), false),
        (@runtime.Decode(message="invalid JSON", body=b"x"), false),
        (@runtime.Config("invalid config"), false),
      ] : Array[(@runtime.SdkError, Bool)]) {
    assert_eq(error.status(), None)
    assert_eq(error.is_retryable(), expected)
  }
  let error = @runtime.Status(
    status=429,
    headers=@http.Headers::new(),
    body=b"",
  )
  assert_eq(error.status(), Some(429))
  assert_false(error.is_retryable())
}

///|
test "classification forwards date clock and millisecond precedence" {
  let headers = @http.Headers::from_array([
    ("Retry-After", "Thu, 01 Jan 1970 00:00:01 GMT"),
  ])
  for ms in [None, Some("9")] {
    if ms is Some(value) {
      headers.set("Retry-After-Ms", value)
    }
    try
      @runtime.classify({ status: 429, headers, body: b"", }, now_unix_ms=0L)
    catch {
      @runtime.RateLimited(retry_after_ms~, ..) =>
        assert_eq(retry_after_ms, Some(if ms is Some(_) { 9 } else { 1000 }))
      _ => fail("expected rate limit")
    } noraise {
      _ => fail("expected error")
    }
  }
}
