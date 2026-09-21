///|
test "all method constructors start empty and preserve URL and custom method" {
  let requests = [
    (@http.Request::new("custom", "/path"), "custom"),
    (@http.Request::get("/path"), "GET"),
    (@http.Request::post("/path"), "POST"),
    (@http.Request::put("/path"), "PUT"),
    (@http.Request::patch("/path"), "PATCH"),
    (@http.Request::delete("/path"), "DELETE"),
  ]
  for (request, http_method) in requests {
    assert_eq(request.http_method, http_method)
    assert_eq(request.url, "/path")
    assert_eq(request.headers.length(), 0)
    assert_eq(request.body, b"")
  }
}

///|
test "builders copy headers and preserve source requests" {
  let original = @http.Request::post("/path").header("X-A", "one")
  let appended = original.header("x-a", "two")
  let bytes = original.body_bytes(b"\xff\x00")
  let text = original.body_text("日本語🌙")
  let json = original.json_body({ "ok": true })
  for derived in [appended, bytes, text, json] {
    derived.headers.append("Only-Derived", "yes")
    assert_true(!original.headers.contains("only-derived"))
    assert_eq(derived.http_method, "POST")
    assert_eq(derived.url, "/path")
  }
  original.headers.set("X-A", "changed")
  assert_eq(appended.headers.get_all("X-A"), ["one", "two"])
  for derived in [bytes, text, json] {
    assert_eq(derived.headers.get_all("X-A"), ["one"])
  }
  assert_eq(original.body, b"")
  assert_eq(bytes.body, b"\xff\x00")
  assert_eq(text.body, @utf8.encode("日本語🌙"))
}

///|
test "json body sets a default content type and preserves existing values" {
  let value : Json = { "message": "日本語🌙", "count": 2 }
  let original = @http.Request::put("/json")
  let request = original.json_body(value)
  assert_true(!original.headers.contains("content-type"))
  assert_eq(request.headers.get_all("Content-Type"), ["application/json"])
  let response : @http.Response = {
    status: 200,
    headers: request.headers,
    body: request.body,
  }
  assert_eq(response.json(), value)
  let custom = original
    .header("Content-TYPE", "custom/type")
    .header("CONTENT-TYPE", "second")
    .json_body(value)
  assert_eq(custom.headers.get_all("content-type"), ["custom/type", "second"])
  let empty = original.header("Content-Type", "").json_body(value)
  assert_eq(empty.headers.get("content-type"), Some(""))
}
