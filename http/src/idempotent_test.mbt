///|
test "idempotency covers methods and idempotency key" {
  for verb in ["GET", "head", "Put", "DELETE", "OPTIONS", "trace"] {
    assert_true(@http.is_idempotent(@http.Request::new(verb, "/")))
  }
  for verb in ["POST", "PATCH", "CONNECT", "unknown"] {
    assert_false(@http.is_idempotent(@http.Request::new(verb, "/")))
  }
  assert_true(
    @http.is_idempotent(
      @http.Request::post("/").header("Idempotency-Key", "request-1"),
    ),
  )
}
