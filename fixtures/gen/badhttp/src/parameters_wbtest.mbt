///|
test "query values percent-encode UTF-8 and reserved delimiters" {
  let request = get_status_code_request("a b日本語&=", retry_after=1)
  assert_eq(
    request.url,
    "/status/a%20b%E6%97%A5%E6%9C%AC%E8%AA%9E%26%3D?retry-after=1",
  )
}
