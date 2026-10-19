///|
/// A `@sync.Timer` that never cancels: it runs the work and records each
/// budget, so the client's arithmetic is checked on a `FakeClock`.
priv struct RecordingTimer {
  budgets : Array[Int32]
}

///|
impl @sync.Timer for RecordingTimer with fn within(self, milliseconds, f) {
  self.budgets.push(milliseconds)
  f()
  true
}

///|
/// Stalls on the real clock for its first `stalls` exchanges, then answers
/// 200.
priv struct StallThenOk {
  mut stalls : Int32
  mut calls : Int32
}

///|
impl @http.Transport for StallThenOk with fn send(self, _request) {
  self.calls += 1
  if self.stalls > 0 {
    self.stalls -= 1
    @async.sleep(60000)
  }
  buffered_response(200, body=b"ok")
}

///|
impl @http.Transport for StallThenOk with fn send_stream(self, _request) {
  self.calls += 1
  if self.stalls > 0 {
    self.stalls -= 1
    @async.sleep(60000)
  }
  raise @http.HttpError::Protocol("unused")
}

///|
/// Answers 500 after moving the fake clock on, like a slow server.
priv struct SlowFailure {
  clock : @mock.FakeClock
  ms : Int32
  mut calls : Int32
}

///|
impl @http.Transport for SlowFailure with fn send(self, _request) {
  self.calls += 1
  self.clock.advance(self.ms)
  buffered_response(500)
}

///|
impl @http.Transport for SlowFailure with fn send_stream(_self, _request) {
  raise @http.HttpError::Protocol("unused")
}

///|
async test "an attempt that runs out of time is retried for GET, not for POST" {
  bounded(() => {
    let attempts : Array[(Int32, Int32, @runtime.SdkError?)] = []
    let timeouts = @runtime.Timeouts::new(
      @adapter.ClockTimer::new(),
      attempt_ms=20,
    )
    let get = StallThenOk::{ stalls: 1, calls: 0, }
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      get,
      clock,
      base_url="https://api.test",
      observer=attempt => {
        attempts.push((attempt.attempt, attempt.status, attempt.error))
      },
      random=() => 0.5,
      timeouts~,
    )
    assert_eq(client.send(@http.Request::get("/slow")).body, b"ok")
    assert_eq(get.calls, 2)
    assert_eq(clock.slept(), [500])
    guard attempts
      is [
        (0, 0, Some(Transport(Timeout(phase=Unknown, ms=20)))),
        (1, 200, None),
      ] else {
      fail("unexpected attempts: \{@debug.to_string(attempts)}")
    }
    // A timeout comes after the request may have been sent.
    let post = StallThenOk::{ stalls: 1, calls: 0, }
    let client = @runtime.Client::new(
      post,
      @mock.FakeClock::new(),
      base_url="https://api.test",
      random=() => 0.5,
      timeouts~,
    )
    try client.send(@http.Request::post("/slow")) catch {
      Transport(Timeout(phase=Unknown, ms=20)) => ()
      error =>
        fail("expected the attempt timeout, got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("a timed-out POST must not be retried")
    }
    assert_eq(post.calls, 1)
    // Only the head of a stream is bounded, and a stalled head is retried.
    let stream = StallThenOk::{ stalls: 3, calls: 0, }
    let client = @runtime.Client::new(
      stream,
      @mock.FakeClock::new(),
      base_url="https://api.test",
      random=() => 0.5,
      timeouts~,
    )
    try client.send_stream(@http.Request::get("/events")) catch {
      Transport(Timeout(phase=Unknown, ms=20)) => ()
      error =>
        fail("expected the attempt timeout, got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("every head stalled")
    }
    assert_eq(stream.calls, 3)
  })
}

///|
async test "the total timeout caps a Retry-After or backoff wait" {
  bounded(() => {
    // The server asks for 2 s with 1 s left: the decider stops (Budget).
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/limited",
      buffered_response(
        503,
        headers=@http.Headers::from_array([("retry-after", "2")]),
      ),
    )
    let timer = RecordingTimer::{ budgets: [], }
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
      random=() => 0.5,
      timeouts=@runtime.Timeouts::new(timer, total_ms=1000),
    )
    try client.send(@http.Request::get("/limited")) catch {
      Status(status=503, ..) => ()
      error => fail("expected the 503, got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("a 2 s wait does not fit in 1 s")
    }
    assert_eq(clock.slept(), [])
    assert_eq(timer.budgets, [1000])
    transport.assert_complete()
    // The first backoff (500 ms) fits; the second (1000 ms) does not. Each
    // exchange gets the smaller of attempt_ms and the time left.
    let clock = @mock.FakeClock::new()
    let slow = SlowFailure::{ clock, ms: 100, calls: 0, }
    let timer = RecordingTimer::{ budgets: [], }
    let client = @runtime.Client::new(
      slow,
      clock,
      base_url="https://api.test",
      random=() => 0.5,
      timeouts=@runtime.Timeouts::new(timer, attempt_ms=700, total_ms=1000),
    )
    try client.send(@http.Request::get("/fail")) catch {
      Status(status=500, ..) => ()
      error => fail("expected the 500, got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("expected a failure")
    }
    assert_eq(clock.slept(), [500])
    assert_eq(slow.calls, 2)
    assert_eq(timer.budgets, [700, 400])
  })
}

///|
async test "no attempt starts once the total timeout has passed" {
  bounded(() => {
    let clock = @mock.FakeClock::new()
    let slow = SlowFailure::{ clock, ms: 400, calls: 0, }
    let timer = RecordingTimer::{ budgets: [], }
    let attempts : Array[Int32] = []
    let client = @runtime.Client::new(
      slow,
      clock,
      base_url="https://api.test",
      retry=AlwaysRetry::{ },
      observer=attempt => attempts.push(attempt.attempt),
      timeouts=@runtime.Timeouts::new(timer, total_ms=1000),
    )
    // 0 → 400 ms, wait 1, 401 → 801, wait 1, 802 → 1202, wait 1: over.
    try client.send(@http.Request::get("/fail")) catch {
      Transport(Timeout(phase=Unknown, ms=1000)) => ()
      error =>
        fail("expected the total timeout, got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("expected a failure")
    }
    assert_eq(slow.calls, 3)
    assert_eq(attempts, [0, 1, 2])
    assert_eq(timer.budgets, [1000, 599, 198])
    // A total that is not positive fails before anything is sent.
    let transport = @mock.FakeTransport::new()
    let client = @runtime.Client::new(
      transport,
      @mock.FakeClock::new(),
      base_url="https://api.test",
      timeouts=@runtime.Timeouts::new(timer, total_ms=0),
    )
    try client.send_stream(@http.Request::get("/events")) catch {
      Transport(Timeout(phase=Unknown, ms=0)) => ()
      error =>
        fail("expected the total timeout, got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("expected a failure")
    }
    assert_eq(transport.sent(), [])
    // Timeouts without a limit leave the exchange alone.
    let transport = @mock.FakeTransport::new()
    transport.expect("GET", "/free", buffered_response(200))
    let unlimited = RecordingTimer::{ budgets: [], }
    let client = @runtime.Client::new(
      transport,
      @mock.FakeClock::new(),
      base_url="https://api.test",
      timeouts=@runtime.Timeouts::new(unlimited),
    )
    assert_eq(client.send(@http.Request::get("/free")).status, 200)
    assert_eq(unlimited.budgets, [])
    transport.assert_complete()
  })
}

///|
async test "an accept hook that raises a retryable error leads to a retry" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/graphql",
      buffered_response(200, body=b"{\"errors\":[{\"type\":\"RATE_LIMITED\"}]}"),
    )
    transport.expect("POST", "/graphql", buffered_response(200, body=b"{}"))
    let observed : Array[(Int32, Int32)] = []
    let clock = @mock.FakeClock::new()
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
      observer=attempt => observed.push((attempt.attempt, attempt.status)),
      random=() => 0.5,
    )
    let accept = (response : @http.Response) => {
      if @utf8.decode_lossy(response.body).contains("RATE_LIMITED") {
        raise @runtime.RateLimited(
          retry_after_ms=Some(1500),
          headers=response.headers,
          body=response.body,
        )
      }
    }
    let json = client.send_json(@http.Request::post("/graphql"), accept~)
    assert_eq(json, Json::object({}))
    assert_eq(observed, [(0, 200), (1, 200)])
    assert_eq(clock.slept(), [1500])
    transport.assert_complete()
    // An error the decider does not retry is raised as it is.
    let transport = @mock.FakeTransport::new()
    transport.expect("GET", "/odd", buffered_response(200, body=b"odd"))
    let client = @runtime.Client::new(
      transport,
      @mock.FakeClock::new(),
      base_url="https://api.test",
    )
    try
      client.send(@http.Request::get("/odd"), accept=response => {
        raise @runtime.Decode(message="unexpected", body=response.body)
      })
    catch {
      Decode(message="unexpected", ..) => ()
      error => fail("expected the hook's error, got \{@debug.to_string(error)}")
    } noraise {
      _ => fail("the hook rejected the response")
    }
    transport.assert_complete()
  })
}

///|
async test "Client honours a Retry-After HTTP date on an error status" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/busy",
      buffered_response(
        503,
        headers=@http.Headers::from_array([
          ("retry-after", "Sun, 09 Sep 2001 01:46:43 GMT"),
        ]),
      ),
    )
    transport.expect("GET", "/busy", buffered_response(200))
    let clock = @mock.FakeClock::new(start_unix_ms=1000000000000L)
    let client = @runtime.Client::new(
      transport,
      clock,
      base_url="https://api.test",
      random=() => 0.5,
    )
    assert_eq(client.send(@http.Request::get("/busy")).status, 200)
    assert_eq(clock.slept(), [3000])
    transport.assert_complete()
  })
}

///|
async test "stainless retries a POST on 500 and obeys x-should-retry" {
  bounded(() => {
    let rows : Array[(Int32, String?, Bool)] = [
      (500, None, true),
      (529, None, true),
      (503, Some("false"), false),
      (400, Some("true"), true),
      (400, None, false),
    ]
    for i, row in rows {
      let (status, should_retry, retried) = row
      let headers = @http.Headers::new()
      if should_retry is Some(value) {
        headers.set("x-should-retry", value)
      }
      let transport = @mock.FakeTransport::new()
      transport.expect(
        "POST",
        "/v1/messages",
        buffered_response(status, headers~),
      )
      if retried {
        transport.expect("POST", "/v1/messages", buffered_response(200))
      }
      let clock = @mock.FakeClock::new()
      let client = @runtime.Client::new(
        transport,
        clock,
        base_url="https://api.test",
        retry=@runtime.RetryPolicy::stainless(cap=NoCap),
        random=() => 0.5,
      )
      let ok = try client.send(@http.Request::post("/v1/messages")) catch {
        Status(status=actual, ..) => {
          assert_eq(actual, status, msg="row \{i}")
          false
        }
        error => fail("row \{i}: \{@debug.to_string(error)}")
      } noraise {
        _ => true
      }
      assert_eq(ok, retried, msg="row \{i}")
      // 500 ms × (750 + 0.5 × 250) ‰.
      assert_eq(clock.slept(), if retried { [437] } else { [] }, msg="row \{i}")
      transport.assert_complete()
    }
  })
}

///|
async test "a long Retry-After stops under StopAbove and is waited under NoCap" {
  bounded(() => {
    let caps : Array[(@runtime.RetryAfterCap, Array[Int32])] = [
      (StopAbove(120000), []),
      (NoCap, [121000]),
    ]
    for case in caps {
      let (cap, waits) = case
      let transport = @mock.FakeTransport::new()
      transport.expect(
        "POST",
        "/v1/responses",
        buffered_response(
          429,
          headers=@http.Headers::from_array([("retry-after", "121")]),
        ),
      )
      if waits is [_] {
        transport.expect("POST", "/v1/responses", buffered_response(200))
      }
      let clock = @mock.FakeClock::new()
      let client = @runtime.Client::new(
        transport,
        clock,
        base_url="https://api.test",
        retry=@runtime.RetryPolicy::stainless(cap~),
        random=() => 0.5,
      )
      let ok = try client.send(@http.Request::post("/v1/responses")) catch {
        RateLimited(retry_after_ms=Some(121000), ..) => false
        error => fail("unexpected \{@debug.to_string(error)}")
      } noraise {
        _ => true
      }
      assert_eq(ok, waits is [_])
      assert_eq(clock.slept(), waits)
      transport.assert_complete()
    }
  })
}

///|
async test "Client observes a cancelled attempt under Timeouts as without" {
  bounded(() => {
    let limiter = SuspendingLimiter::{ released: 0, }
    let attempts : Array[(Int32, Int32)] = []
    let client = @runtime.Client::new(
      Stalled::{ },
      @mock.FakeClock::new(),
      base_url="https://api.test",
      limiter~,
      observer=attempt => attempts.push((attempt.attempt, attempt.status)),
      timeouts=@runtime.Timeouts::new(
        @adapter.ClockTimer::new(),
        attempt_ms=60000,
        total_ms=60000,
      ),
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
