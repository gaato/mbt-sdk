///|
test "Auth redacts every secret and preserves explicit request headers" {
  let token = "token-that-must-not-leak"
  let header_secret = "header-secret-that-must-not-leak"
  let bearer_repr = @debug.Repr(@runtime.Bearer(token)).to_string()
  let header_repr = @debug.Repr(@runtime.Header("X-Api-Key", header_secret)).to_string()
  assert_eq(bearer_repr, "Bearer(<redacted>)")
  assert_eq(header_repr, "Header(\"X-Api-Key\", <redacted>)")
  assert_false(bearer_repr.contains(token))
  assert_false(header_repr.contains(header_secret))
  let original = @http.Request::get("/")
  let authenticated = @runtime.Bearer(token).apply(original)
  assert_eq(authenticated.headers.get("authorization"), Some("Bearer " + token))
  assert_eq(original.headers.get("authorization"), None)
  let explicit = @http.Request::get("/").header("Authorization", "Basic kept")
  assert_eq(
    @runtime.Bearer(token).apply(explicit).headers.get("authorization"),
    Some("Basic kept"),
  )
  let custom = @http.Request::get("/").header("X-Api-Key", "kept")
  assert_eq(
    @runtime.Header("x-api-key", header_secret).apply(custom).headers.get(
      "x-api-key",
    ),
    Some("kept"),
  )
  assert_eq(@runtime.NoAuth.apply(original), original)
}

///|
test "idempotency covers methods and idempotency key" {
  for verb in ["GET", "head", "Put", "DELETE", "OPTIONS", "trace"] {
    assert_true(@runtime.is_idempotent(@http.Request::new(verb, "/")))
  }
  for verb in ["POST", "PATCH", "CONNECT", "unknown"] {
    assert_false(@runtime.is_idempotent(@http.Request::new(verb, "/")))
  }
  assert_true(
    @runtime.is_idempotent(
      @http.Request::post("/").header("Idempotency-Key", "request-1"),
    ),
  )
}

///|
test "RetryPolicy defaults and none" {
  let expected : @runtime.RetryPolicy = {
    max_retries: 2,
    backoff: @runtime.Backoff::default(),
    max_retry_after_ms: 60000,
    retry_non_idempotent: false,
  }
  assert_eq(@runtime.RetryPolicy::default(), expected)
  assert_eq(@runtime.RetryPolicy::none(), { ..expected, max_retries: 0, })
}

///|
test "next_delay retryability idempotency attempts and special failures table" {
  let policy = @runtime.RetryPolicy::default()
  let get = @http.Request::get("/")
  let post = @http.Request::post("/")
  let keyed_post = post.header("idempotency-key", "key")
  let empty = @http.Headers::new()
  let cases : Array[(@runtime.SdkError, Bool, Bool)] = [
    (@runtime.Transport(@http.Connect("offline")), true, true),
    (@runtime.Transport(@http.Timeout(1)), true, false),
    (@runtime.Transport(@http.Protocol("bad")), false, false),
    (@runtime.Status(status=408, headers=empty, body=b""), true, false),
    (@runtime.Status(status=409, headers=empty, body=b""), true, false),
    (@runtime.Status(status=500, headers=empty, body=b""), true, false),
    (@runtime.Status(status=502, headers=empty, body=b""), true, false),
    (@runtime.Status(status=503, headers=empty, body=b""), true, false),
    (@runtime.Status(status=504, headers=empty, body=b""), true, false),
    (@runtime.Status(status=400, headers=empty, body=b""), false, false),
    (
      @runtime.RateLimited(retry_after_ms=None, headers=empty, body=b""),
      true,
      true,
    ),
    (@runtime.Decode(message="bad", body=b""), false, false),
    (@runtime.Config("bad"), false, false),
  ]
  for (error, retryable, non_idempotent_exception) in cases {
    let expected = if retryable { Some(400) } else { None }
    assert_eq(policy.next_delay_ms(error, get, 0, 0.0), expected)
    assert_eq(policy.next_delay_ms(error, keyed_post, 0, 0.0), expected)
    assert_eq(
      policy.next_delay_ms(error, post, 0, 0.0),
      if retryable && non_idempotent_exception {
        Some(400)
      } else {
        None
      },
    )
    assert_eq(policy.next_delay_ms(error, get, 2, 0.0), None)
    assert_eq(
      @runtime.RetryPolicy::none().next_delay_ms(error, get, 0, 0.0),
      None,
    )
  }
  let permissive = { ..policy, retry_non_idempotent: true, }
  assert_eq(
    permissive.next_delay_ms(@runtime.Transport(@http.Timeout(1)), post, 0, 0.0),
    Some(400),
  )
}

///|
test "next_delay honors Retry-After sources and upper bound" {
  let policy = { ..@runtime.RetryPolicy::default(), max_retry_after_ms: 1500, }
  let request = @http.Request::get("/")
  for
    (error, expected) in (
      [
        (
          @runtime.RateLimited(
            retry_after_ms=Some(0),
            headers=@http.Headers::new(),
            body=b"",
          ),
          Some(0),
        ),
        (
          @runtime.RateLimited(
            retry_after_ms=Some(1500),
            headers=@http.Headers::new(),
            body=b"",
          ),
          Some(1500),
        ),
        (
          @runtime.RateLimited(
            retry_after_ms=Some(1501),
            headers=@http.Headers::new(),
            body=b"",
          ),
          None,
        ),
        (
          @runtime.Status(
            status=503,
            headers=@http.Headers::from_array([("retry-after", "1.5")]),
            body=b"",
          ),
          Some(1500),
        ),
        (
          @runtime.Status(
            status=503,
            headers=@http.Headers::from_array([("retry-after-ms", "1501")]),
            body=b"",
          ),
          None,
        ),
        (
          @runtime.Status(
            status=503,
            headers=@http.Headers::from_array([("retry-after", "bad")]),
            body=b"",
          ),
          Some(400),
        ),
      ] : Array[(@runtime.SdkError, Int?)]) {
    assert_eq(policy.next_delay_ms(error, request, 0, 0.0), expected)
  }
}
