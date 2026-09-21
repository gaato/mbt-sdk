///|
test "Request equality and debug include all fields" {
  let request = @http.Request::get("/x").header("A", "1").body_text("x")
  assert_eq(request, @http.Request::get("/x").header("a", "1").body_text("x"))
  assert_true(request != { ..request, http_method: "POST", })
  assert_true(request != { ..request, url: "/y", })
  assert_true(request != request.header("a", "2"))
  assert_true(request != request.body_text("y"))
  assert_true("\{Repr(request)}".contains("http_method"))
}

///|
test "Response equality and debug include all fields" {
  let response : @http.Response = {
    status: 200,
    headers: @http.Headers::new(),
    body: b"x",
  }
  assert_eq(response, {
    status: 200,
    headers: @http.Headers::new(),
    body: b"x",
  })
  assert_true(response != { ..response, status: 500, })
  assert_true(response != { ..response, body: b"y", })
  assert_true(
    response !=
    { ..response, headers: @http.Headers::from_array([("x", "y")]), },
  )
  assert_true("\{Repr(response)}".contains("status"))
}

///|
test "ResponseHead equality and debug include all fields" {
  let head : @http.ResponseHead = {
    status: 201,
    headers: @http.Headers::new(),
  }
  assert_eq(head, { status: 201, headers: @http.Headers::new(), })
  assert_true(head != { ..head, status: 200, })
  assert_true(
    head != { ..head, headers: @http.Headers::from_array([("x", "y")]), },
  )
  assert_true("\{Repr(head)}".contains("status"))
}
