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
