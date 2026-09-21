///|
async test "unknown methods and invalid URLs are Protocol before connecting" {
  let transport = @adapter.AsyncTransport::new()
  let unknown = {
    ..@http.Request::get("http://127.0.0.1:1"),
    http_method: "CUSTOM",
  }
  let requests = [
    unknown,
    @http.Request::get("relative"),
    @http.Request::get("ftp://127.0.0.1"),
    @http.Request::get("http:///empty"),
  ]
  for request in requests {
    for streaming in [false, true] {
      try {
        if streaming {
          ignore(transport.send_stream(request))
        } else {
          ignore(transport.send(request))
        }
      } catch {
        @http.HttpError::Protocol(_) => ()
        _ => fail("expected Protocol")
      } noraise {
        _ => fail("expected validation error")
      }
    }
  }
}

///|
async test "nonpositive timeouts expire immediately with their original value" {
  for ms in [0, -1] {
    for streaming in [false, true] {
      let transport = @adapter.AsyncTransport::new(timeout_ms=ms)
      try {
        let request = @http.Request::get("http://127.0.0.1:1")
        if streaming {
          ignore(transport.send_stream(request))
        } else {
          ignore(transport.send(request))
        }
      } catch {
        @http.HttpError::Timeout(actual) => assert_eq(actual, ms)
        _ => fail("expected immediate Timeout")
      } noraise {
        _ => fail("expected timeout")
      }
    }
  }
}
