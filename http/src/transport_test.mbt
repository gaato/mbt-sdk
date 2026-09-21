///|
struct TestTransport {
  calls : Array[String]
}

///|
impl @http.Transport for TestTransport with fn send(self, request) {
  self.calls.push("send:" + request.url)
  { status: 503, headers: request.headers, body: request.body, }
}

///|
impl @http.Transport for TestTransport with fn send_stream(_self, _request) {
  raise @http.HttpError::Protocol("stream unused in this test")
}

///|
// Compile-only: async test requires moonbitlang/async even for an in-memory transport.
async fn middleware_ordering() -> Unit {
  let calls = []
  let transport : &@http.Transport = TestTransport::{ calls, }
  let first : @http.Middleware = (request, next) => {
    calls.push("first:before")
    let response = next(request.header("X-Order", "first"))
    calls.push("first:after")
    response
  }
  let second : @http.Middleware = (request, next) => {
    calls.push("second:before")
    let response = next(request.header("X-Order", "second"))
    calls.push("second:after")
    response
  }
  let request = @http.Request::get("/test").body_text("payload")
  let response = @http.send_with(transport, [first, second], request)
  assert_eq(calls, [
    "first:before", "second:before", "send:/test", "second:after", "first:after",
  ])
  assert_eq(response.headers.get_all("x-order"), ["first", "second"])
  assert_eq(response.status, 503)
  assert_eq(response.body, b"payload")
  assert_eq(request.headers.length(), 0)
  calls.clear()
  let response = @http.send_with(transport, [], request)
  assert_eq(calls, ["send:/test"])
  assert_eq(response.status, 503)
}

///|
test "middleware ordering scenario compiles without a runtime dependency" {
  let _ : async () -> Unit = middleware_ordering
}
