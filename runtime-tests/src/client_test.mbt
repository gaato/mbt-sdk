///|
fn buffered_response(
  status : Int,
  headers? : @http.Headers = @http.Headers::new(),
  body? : Bytes = b"",
) -> @http.Response {
  { status, headers, body, }
}

///|
async fn bounded(f : async () -> Unit) -> Unit {
  @async.with_timeout(5000, f)
}

///|
async test "Client resolves URLs and injects defaults and authentication" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("GET", "/v1/items", buffered_response(200))
    transport.expect("GET", "/absolute", buffered_response(200))
    let clock = @mock.FakeClock::new(start_unix_ms=1000L)
    let defaults = @http.Headers::from_array([
      ("X-Default", "one"),
      ("X-Default", "two"),
      ("X-Kept", "default"),
    ])
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test/",
      default_headers=defaults,
      auth=@runtime.Bearer("secret"),
      random=() => 0.5,
    )
    ignore(
      client.send(@http.Request::get("/v1/items").header("X-Kept", "request")),
    )
    ignore(client.send(@http.Request::get("https://other.test/absolute")))
    let sent = transport.sent()
    assert_eq(sent[0].url, "https://api.test/v1/items")
    assert_eq(sent[0].headers.get_all("x-default"), ["one", "two"])
    assert_eq(sent[0].headers.get("x-kept"), Some("request"))
    assert_eq(sent[0].headers.get("authorization"), Some("Bearer secret"))
    assert_eq(sent[1].url, "https://other.test/absolute")
    assert_eq(clock.slept(), [])
    transport.assert_complete()
  })
}

///|
async test "Client retries 500 twice then succeeds with backoff sleeps" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("GET", "/retry", buffered_response(500, body=b"first"))
    transport.expect("GET", "/retry", buffered_response(500, body=b"second"))
    transport.expect("GET", "/retry", buffered_response(200, body=b"ok"))
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
      random=() => 0.5,
    )
    let response = client.send(@http.Request::get("/retry"))
    assert_eq(response.body, b"ok")
    assert_eq(clock.slept(), [500, 1000])
    assert_eq(transport.sent().length(), 3)
    transport.assert_complete()
  })
}

///|
async test "Client stops at max retries and raises the final error" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    for body in [b"first", b"second", b"last"] {
      transport.expect("GET", "/fail", buffered_response(500, body~))
    }
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
      random=() => 0.5,
    )
    try client.send(@http.Request::get("/fail")) catch {
      @runtime.Status(status=500, body=b"last", ..) => ()
      _ => fail("expected final 500 response")
    } noraise {
      _ => fail("expected retry exhaustion")
    }
    assert_eq(clock.slept(), [500, 1000])
    transport.assert_complete()
  })
}

///|
priv struct ConnectThenSuccess {
  mut calls : Int
}

///|
impl @http.Transport for ConnectThenSuccess with fn send(self, _request) {
  self.calls += 1
  if self.calls == 1 {
    raise @http.HttpError::Connect("offline")
  }
  buffered_response(200, body=b"connected")
}

///|
impl @http.Transport for ConnectThenSuccess with fn send_stream(_self, _request) {
  raise @http.HttpError::Protocol("unused")
}

///|
async test "POST retry exceptions are 429 Connect and idempotency key" {
  bounded(() => {
    let no_retry = @mock.FakeTransport::new()
    no_retry.expect("POST", "/post-500", buffered_response(500))
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      no_retry,
      clock,
      base_url="https://api.test",
      random=() => 0.5,
    )
    try client.send(@http.Request::post("/post-500")) catch {
      @runtime.Status(status=500, ..) => ()
      _ => fail("expected 500")
    } noraise {
      _ => fail("POST 500 must not retry")
    }
    assert_eq(clock.slept(), [])
    no_retry.assert_complete()

    let limited = @mock.FakeTransport::new()
    limited.expect(
      "POST",
      "/limited",
      buffered_response(
        429,
        headers=@http.Headers::from_array([("retry-after", "0")]),
      ),
    )
    limited.expect("POST", "/limited", buffered_response(200))
    let limited_clock = @mock.FakeClock::new()
    let limited_client = @runtime.Client::new(
      limited,
      limited_clock,
      base_url="https://api.test",
      random=() => 0.5,
    )
    ignore(limited_client.send(@http.Request::post("/limited")))
    assert_eq(limited_clock.slept(), [0])
    limited.assert_complete()

    let connecting = ConnectThenSuccess::{ calls: 0, }
    let connect_clock = @mock.FakeClock::new()
    let connect_client = @runtime.Client::new(
      connecting,
      connect_clock,
      base_url="https://api.test",
      random=() => 0.5,
    )
    assert_eq(
      connect_client.send(@http.Request::post("/connect")).body,
      b"connected",
    )
    assert_eq(connecting.calls, 2)
    assert_eq(connect_clock.slept(), [500])

    let keyed = @mock.FakeTransport::new()
    keyed.expect("POST", "/keyed", buffered_response(500))
    keyed.expect("POST", "/keyed", buffered_response(200))
    let keyed_clock = @mock.FakeClock::new()
    let keyed_client = @runtime.Client::new(
      keyed,
      keyed_clock,
      base_url="https://api.test",
      random=() => 0.5,
    )
    ignore(
      keyed_client.send(
        @http.Request::post("/keyed").header("idempotency-key", "key"),
      ),
    )
    assert_eq(keyed_clock.slept(), [500])
    keyed.assert_complete()
  })
}

///|
async test "Retry-After above the policy cap is not retried" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/long-wait",
      buffered_response(
        429,
        headers=@http.Headers::from_array([("retry-after", "60.001")]),
      ),
    )
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
      random=() => 0.5,
    )
    try client.send(@http.Request::get("/long-wait")) catch {
      @runtime.RateLimited(retry_after_ms=Some(60001), ..) => ()
      _ => fail("expected capped rate limit error")
    } noraise {
      _ => fail("must not retry excessive Retry-After")
    }
    assert_eq(clock.slept(), [])
    transport.assert_complete()
  })
}

///|
async test "send_json maps empty bodies to null and invalid JSON to Decode" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("GET", "/empty", buffered_response(204))
    transport.expect("GET", "/invalid", buffered_response(200, body=b"{"))
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
    )
    assert_eq(client.send_json(@http.Request::get("/empty")), Json::null())
    try client.send_json(@http.Request::get("/invalid")) catch {
      @runtime.Decode(body=b"{", ..) => ()
      _ => fail("expected Decode")
    } noraise {
      _ => fail("invalid JSON must fail")
    }
    transport.assert_complete()
  })
}

///|
async test "send_stream returns success and closes classified error streams" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect_stream(
      "GET",
      "/ok-stream",
      { status: 200, headers: @http.Headers::new(), },
      [b"ok"],
    )
    transport.expect_stream(
      "GET",
      "/bad-stream",
      { status: 400, headers: @http.Headers::new(), },
      [b"er", b"ror"],
    )
    transport.expect_stream(
      "GET",
      "/large-stream",
      { status: 400, headers: @http.Headers::new(), },
      [Bytes::make(1048580, b'x')],
    )
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
    )
    let (head, stream) = client.send_stream(@http.Request::get("/ok-stream"))
    assert_eq(head.status, 200)
    assert_eq(stream.read_some(), Some(b"ok"))
    stream.close()
    try client.send_stream(@http.Request::get("/bad-stream")) catch {
      @runtime.Status(status=400, body=b"error", ..) => ()
      _ => fail("expected classified stream body")
    } noraise {
      _ => fail("expected 400")
    }
    try client.send_stream(@http.Request::get("/large-stream")) catch {
      @runtime.Status(status=400, body~, ..) =>
        assert_eq(body.length(), 1048576)
      _ => fail("expected truncated classified stream body")
    } noraise {
      _ => fail("expected 400")
    }
    assert_eq(transport.streams_closed(), 3)
    transport.assert_complete()
  })
}

///|
/// Records every `acquire` and `release` a client makes, with the released
/// status, so a test can check that they pair up on every exit.
priv struct PairingLimiter {
  acquired : Array[(String, Bool)]
  released : Array[(String, Int)]
}

///|
impl @runtime.RateLimiter for PairingLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  self.acquired.push((bucket, global_exempt))
}

///|
impl @runtime.RateLimiter for PairingLimiter with fn release(
  self,
  bucket,
  status~,
  headers~,
) {
  ignore(headers)
  self.released.push((bucket, status))
}

///|
priv struct AlwaysConnectError {}

///|
impl @http.Transport for AlwaysConnectError with fn send(_self, _request) {
  raise @http.HttpError::Connect("offline")
}

///|
impl @http.Transport for AlwaysConnectError with fn send_stream(_self, _request) {
  raise @http.HttpError::Connect("offline")
}

///|
async test "Client releases with status 0 and observes an attempt without a response" {
  bounded(() => {
    let limiter = PairingLimiter::{ acquired: [], released: [], }
    let attempts : Array[(Int, Int, Bool)] = []
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      AlwaysConnectError::{ },
      clock,
      base_url="https://api.test",
      retry=@runtime.RetryPolicy::none(),
      limiter~,
      observer=attempt => {
        attempts.push(
          (attempt.attempt, attempt.status, attempt.error is Some(_)),
        )
      },
    )
    try
      client.send(@http.Request::get("/down"), bucket="b", global_exempt=true)
    catch {
      @runtime.Transport(@http.Connect("offline")) => ()
      _ => fail("expected the connect failure")
    } noraise {
      _ => fail("expected a failure")
    }
    assert_eq(limiter.acquired, [("b", true)])
    assert_eq(limiter.released, [("b", 0)])
    assert_eq(attempts, [(0, 0, true)])
    try client.send_stream(@http.Request::get("/down"), bucket="s") catch {
      @runtime.Transport(@http.Connect("offline")) => ()
      _ => fail("expected the connect failure")
    } noraise {
      _ => fail("expected a failure")
    }
    assert_eq(limiter.released, [("b", 0), ("s", 0)])
  })
}

///|
/// A limiter whose `release` awaits, as a limiter backed by another process
/// does, and so can be cut short by cancellation.
priv struct SuspendingLimiter {
  mut released : Int
}

///|
impl @runtime.RateLimiter for SuspendingLimiter with fn acquire(
  _self,
  _bucket,
  global_exempt~,
) {
  ignore(global_exempt)
}

///|
impl @runtime.RateLimiter for SuspendingLimiter with fn release(
  self,
  _bucket,
  status~,
  headers~,
) {
  ignore(status)
  ignore(headers)
  self.released += 1
  @async.sleep(60000)
}

///|
priv struct Stalled {}

///|
impl @http.Transport for Stalled with fn send(_self, _request) {
  @async.sleep(60000)
  buffered_response(200)
}

///|
impl @http.Transport for Stalled with fn send_stream(_self, _request) {
  @async.sleep(60000)
  raise @http.HttpError::Protocol("unreachable")
}

///|
async test "Client observes a cancelled attempt even when the release suspends" {
  bounded(() => {
    let limiter = SuspendingLimiter::{ released: 0, }
    let attempts : Array[(Int, Int)] = []
    let client = @runtime.Client::new(
      Stalled::{ },
      @mock.FakeClock::new(),
      base_url="https://api.test",
      limiter~,
      observer=attempt => attempts.push((attempt.attempt, attempt.status)),
    )
    let buffered = @async.with_timeout_opt(20, () => {
      ignore(client.send(@http.Request::get("/slow")))
    })
    assert_true(buffered is None)
    assert_eq(limiter.released, 1)
    assert_eq(attempts, [(0, 0)])
    let streamed = @async.with_timeout_opt(20, () => {
      ignore(client.send_stream(@http.Request::get("/slow")))
    })
    assert_true(streamed is None)
    assert_eq(limiter.released, 2)
    assert_eq(attempts, [(0, 0), (0, 0)])
  })
}

///|
priv suberror ReleaseRejected derive(Debug)

///|
/// A limiter whose `release` fails, as a remote limiter does for a lease it
/// no longer knows.
priv struct RejectingLimiter {}

///|
impl @runtime.RateLimiter for RejectingLimiter with fn acquire(
  _self,
  _bucket,
  global_exempt~,
) {
  ignore(global_exempt)
}

///|
impl @runtime.RateLimiter for RejectingLimiter with fn release(
  _self,
  _bucket,
  status~,
  headers~,
) {
  ignore(status)
  ignore(headers)
  raise ReleaseRejected
}

///|
async test "Client closes a stream it cannot hand over after a failed release" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    for _ in 0..<2 {
      transport.expect_stream(
        "GET",
        "/stream",
        { status: 200, headers: @http.Headers::new(), },
        [b"ok"],
      )
    }
    let rejecting = @runtime.Client::new(
      transport,
      @mock.FakeClock::new(),
      base_url="https://api.test",
      limiter=RejectingLimiter::{ },
    )
    try rejecting.send_stream(@http.Request::get("/stream")) catch {
      @runtime.Config(message) =>
        assert_true(message.contains("rate limiter release failed"))
      _ => fail("expected the release failure")
    } noraise {
      _ => fail("expected a failure")
    }
    assert_eq(transport.streams_closed(), 1)
    let suspending = @runtime.Client::new(
      transport,
      @mock.FakeClock::new(),
      base_url="https://api.test",
      limiter=SuspendingLimiter::{ released: 0, },
    )
    let handed = @async.with_timeout_opt(20, () => {
      ignore(suspending.send_stream(@http.Request::get("/stream")))
    })
    assert_true(handed is None)
    assert_eq(transport.streams_closed(), 2)
    transport.assert_complete()
  })
}

///|
async test "Client releases every attempt and observes them before retrying" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/limited",
      buffered_response(
        429,
        headers=@http.Headers::from_array([("retry-after", "2")]),
      ),
    )
    transport.expect("GET", "/limited", buffered_response(200, body=b"ok"))
    let limiter = PairingLimiter::{ acquired: [], released: [], }
    let order : Array[String] = []
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
      limiter~,
      observer=attempt => {
        order.push(
          "attempt \{attempt.attempt} status \{attempt.status} bucket \{attempt.bucket}",
        )
      },
      random=() => 0.5,
    )
    let response = client.send(@http.Request::get("/limited"), bucket="l")
    assert_eq(response.body, b"ok")
    assert_eq(limiter.acquired, [("l", false), ("l", false)])
    assert_eq(limiter.released, [("l", 429), ("l", 200)])
    assert_eq(order, [
      "attempt 0 status 429 bucket l", "attempt 1 status 200 bucket l",
    ])
    assert_eq(clock.slept(), [2000])
    transport.assert_complete()
  })
}

///|
priv struct NeverRetry {}

///|
impl @runtime.RetryDecider for NeverRetry with fn next_delay_ms(
  _self,
  _error,
  _request,
  _attempt,
  _random,
) {
  None
}

///|
async test "Client asks the supplied retry decider" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("GET", "/once", buffered_response(500))
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
      retry=NeverRetry::{ },
    )
    try client.send(@http.Request::get("/once")) catch {
      @runtime.Status(status=500, ..) => ()
      _ => fail("expected the 500")
    } noraise {
      _ => fail("expected a failure")
    }
    assert_eq(clock.slept(), [])
    transport.assert_complete()
  })
}
