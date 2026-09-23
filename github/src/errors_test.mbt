///|
fn body(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
fn status_error(
  status : Int,
  headers? : @http.Headers = @http.Headers::new(),
  body? : Bytes = b"",
) -> @runtime.SdkError {
  if status == 429 {
    @runtime.RateLimited(retry_after_ms=None, headers~, body~)
  } else {
    @runtime.Status(status~, headers~, body~)
  }
}

///|
test "api_error reads a plain GitHub error body" {
  let not_found =
    #|{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/repos#get-a-repository","status":"404"}
  assert_eq(
    @github.api_error(status_error(404, body=body(not_found))),
    Some({
      message: "Not Found",
      documentation_url: Some(
        "https://docs.github.com/rest/repos/repos#get-a-repository",
      ),
      status: Some("404"),
      errors: None,
    }),
  )
}

///|
test "api_error keeps the per-field errors of a validation failure" {
  let validation =
    #|{"message":"Validation Failed","errors":[{"resource":"Issue","code":"missing_field","field":"title"}],"documentation_url":"https://docs.github.com/rest/issues/issues#create-an-issue","status":"422"}
  guard @github.api_error(status_error(422, body=body(validation)))
    is Some(parsed) else {
    fail("expected a decoded error body")
  }
  assert_eq(parsed.message, "Validation Failed")
  assert_eq(parsed.status, Some("422"))
  assert_eq(
    parsed.errors,
    Some([{ "resource": "Issue", "code": "missing_field", "field": "title" }]),
  )
}

///|
test "api_error tolerates a numeric status and a missing documentation url" {
  let forbidden =
    #|{"message":"Forbidden","status":403}
  assert_eq(
    @github.api_error(status_error(403, body=body(forbidden))),
    Some({
      message: "Forbidden",
      documentation_url: None,
      status: Some("403"),
      errors: None,
    }),
  )
}

///|
test "api_error returns None for bodies and failures that are not GitHub errors" {
  assert_eq(@github.api_error(status_error(502)), None)
  assert_eq(
    @github.api_error(status_error(502, body=body("<html>bad gateway</html>"))),
    None,
  )
  let unrelated =
    #|{"error":"boom"}
  assert_eq(@github.api_error(status_error(500, body=body(unrelated))), None)
  assert_eq(
    @github.api_error(@runtime.Transport(@http.HttpError::Timeout(1000))),
    None,
  )
  assert_eq(@github.api_error(@runtime.Config("no base url")), None)
}

///|
test "is_not_modified recognises the answer to a conditional request" {
  assert_true(@github.is_not_modified(status_error(304)))
  assert_false(@github.is_not_modified(status_error(404)))
  assert_false(@github.is_not_modified(status_error(429)))
  assert_false(
    @github.is_not_modified(@runtime.Transport(@http.HttpError::Connect("x"))),
  )
}

///|
test "is_secondary_rate_limit separates the secondary limit from the hourly quota" {
  let secondary =
    #|{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits"}
  let primary =
    #|{"message":"API rate limit exceeded for 203.0.113.1. (But here's the good news: Authenticated requests get a higher rate limit.)","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}

  // 403 with retry-after: the documented secondary-limit response.
  let retry_after = @http.Headers::from_array([("retry-after", "60")])
  assert_true(
    @github.is_secondary_rate_limit(
      status_error(403, headers=retry_after, body=body(secondary)),
    ),
  )
  // 429 reaches the caller as RateLimited, not Status.
  assert_true(
    @github.is_secondary_rate_limit(
      status_error(429, headers=retry_after, body=body(secondary)),
    ),
  )
  // Without retry-after the body still names the mechanism.
  assert_true(
    @github.is_secondary_rate_limit(status_error(403, body=body(secondary))),
  )
  // The hourly quota is a different mechanism: WindowLimiter paces it.
  let exhausted = @http.Headers::from_array([
    ("x-ratelimit-remaining", "0"),
    ("x-ratelimit-reset", "1700000000"),
  ])
  assert_false(
    @github.is_secondary_rate_limit(
      status_error(403, headers=exhausted, body=body(primary)),
    ),
  )
  assert_false(
    @github.is_secondary_rate_limit(
      status_error(429, headers=exhausted, body=body(primary)),
    ),
  )
  // Other failures are never a secondary limit.
  assert_false(
    @github.is_secondary_rate_limit(
      status_error(404, headers=retry_after, body=body(secondary)),
    ),
  )
  assert_false(
    @github.is_secondary_rate_limit(
      @runtime.Transport(@http.HttpError::Timeout(1000)),
    ),
  )
}

///|
test "Debug hides the token a client was built with" {
  let token = "ghp-token-that-must-not-leak"
  let client = @github.GitHub::new(
    @mock.FakeTransport::new(),
    @mock.FakeClock::new(),
    token~,
  )
  let representation = @debug.Repr(client).to_string()
  assert_eq(representation, "GitHub(<credentials redacted>)")
  assert_false(representation.contains(token))
}
