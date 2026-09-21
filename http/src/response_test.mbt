///|
test "text strictly decodes multibyte UTF-8" {
  let response : @http.Response = {
    status: 200,
    headers: @http.Headers::new(),
    body: @utf8.encode("こんにちは🌙"),
  }
  assert_eq(response.text(), "こんにちは🌙")
  for
    body in (
      [b"\xff", b"\xc0\xaf", b"\xe3\x81", b"\xed\xa0\x80", b"\xf4\x90\x80\x80"] :
      Array[Bytes]) {
    let malformed : @http.Response = { ..response, body, }
    try malformed.text() catch {
      _ => ()
    } noraise {
      _ => fail("malformed UTF-8 must raise")
    }
  }
}

///|
test "json parses and raises on invalid JSON or malformed UTF-8" {
  let response : @http.Response = {
    status: 400,
    headers: @http.Headers::new(),
    body: b"{\"ok\":true}",
  }
  assert_eq(response.json(), { "ok": true })
  for body in ([b"{", b"null trailing", b"\"\xff\""] : Array[Bytes]) {
    let invalid : @http.Response = { ..response, body, }
    try invalid.json() catch {
      _ => ()
    } noraise {
      _ => fail("invalid JSON must raise")
    }
  }
}

///|
test "success status boundaries and response head fields" {
  for
    (status, expected) in [
      (199, false),
      (200, true),
      (299, true),
      (300, false),
      (404, false),
      (500, false),
    ] {
    let response : @http.Response = {
      status,
      headers: @http.Headers::new(),
      body: b"",
    }
    assert_eq(response.is_success(), expected)
    let head : @http.ResponseHead = {
      status: response.status,
      headers: response.headers,
    }
    assert_eq(head.status, status)
    assert_eq(head.headers.length(), 0)
  }
}
