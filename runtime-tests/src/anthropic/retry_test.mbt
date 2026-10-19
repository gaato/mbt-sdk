// The official SDK's retries (anthropic-sdk-python `_base_client.py`), which
// `Anthropic::new` adopts by default: see docs/behavior/anthropic.md.

///|
/// A `@sync.Timer` that records each budget and reports the first `expire`
/// exchanges as out of time without running them.
priv struct ScriptedTimer {
  budgets : Array[Int32]
  mut expire : Int32
}

///|
impl @sync.Timer for ScriptedTimer with fn within(self, milliseconds, f) {
  self.budgets.push(milliseconds)
  if self.expire > 0 {
    self.expire -= 1
    return false
  }
  f()
  true
}

///|
let message_ok : String = "{\"id\":\"m\",\"model\":\"model\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}"

///|
async fn ask(client : @anthropic_sdk.Anthropic) -> Unit raise @runtime.SdkError {
  ignore(
    client.create_message(
      @anthropic_sdk.MessageRequest::new(model="model", max_tokens=1, messages=[]),
    ),
  )
}

///|
/// Asserts each wait lies within the Stainless backoff for its retry: 500 ms
/// doubling up to 8 s, shortened by up to a quarter.
fn assert_stainless_backoff(slept : Array[Int32]) -> Unit raise {
  for i, wait in slept {
    let full = (500 * (1 << i)).min(8000)
    assert_true(wait >= full * 3 / 4 && wait <= full, msg="wait \{i}: \{wait}")
  }
}

///|
async test "a POST is retried on 500 and on 529 overloaded" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
        status=529,
      ),
    )
    transport.expect("POST", "/v1/messages", json_response("{}", status=500))
    transport.expect("POST", "/v1/messages", json_response(message_ok))
    let clock = @mock.FakeClock::new()
    ask(@anthropic_sdk.Anthropic::new(api_key="key", transport, clock))
    assert_eq(clock.slept().length(), 2)
    assert_stainless_backoff(clock.slept())
    transport.assert_complete()

    let failing = @mock.FakeTransport::new()
    for _ in 0..<3 {
      failing.expect("POST", "/v1/messages", json_response("{}", status=529))
    }
    let clock = @mock.FakeClock::new()
    try
      ask(@anthropic_sdk.Anthropic::new(api_key="key", failing, clock))
    catch {
      error => assert_eq(error.status(), Some(529))
    } noraise {
      _ => fail("the third 529 must be raised")
    }
    assert_eq(clock.slept().length(), 2)
    assert_stainless_backoff(clock.slept())
    failing.assert_complete()
  })
}

///|
async test "conservative() keeps a POST from being retried on 529" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("POST", "/v1/messages", json_response("{}", status=529))
    let clock = @mock.FakeClock::new()
    let client = @anthropic_sdk.Anthropic::new(
      api_key="key",
      transport,
      clock,
      retry=@runtime.RetryPolicy::conservative(),
    )
    try ask(client) catch {
      error => assert_eq(error.status(), Some(529))
    } noraise {
      _ => fail("529 must be raised")
    }
    assert_eq(clock.slept(), [])
    transport.assert_complete()
  })
}

///|
async test "x-should-retry overrides the status rules" {
  bounded(() => {
    let refused = @mock.FakeTransport::new()
    refused.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{}",
        status=500,
        headers=@http.Headers::from_array([("x-should-retry", "false")]),
      ),
    )
    let clock = @mock.FakeClock::new()
    try
      ask(@anthropic_sdk.Anthropic::new(api_key="key", refused, clock))
    catch {
      error => assert_eq(error.status(), Some(500))
    } noraise {
      _ => fail("x-should-retry: false must stop")
    }
    assert_eq(clock.slept(), [])
    refused.assert_complete()

    let forced = @mock.FakeTransport::new()
    forced.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{}",
        status=400,
        headers=@http.Headers::from_array([("x-should-retry", "true")]),
      ),
    )
    forced.expect("POST", "/v1/messages", json_response(message_ok))
    let clock = @mock.FakeClock::new()
    ask(@anthropic_sdk.Anthropic::new(api_key="key", forced, clock))
    assert_eq(clock.slept().length(), 1)
    forced.assert_complete()
  })
}

///|
async test "any Retry-After is waited out, unless the total limit cannot fit it" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{}",
        status=429,
        headers=@http.Headers::from_array([("retry-after", "121")]),
      ),
    )
    transport.expect("POST", "/v1/messages", json_response(message_ok))
    let clock = @mock.FakeClock::new()
    ask(@anthropic_sdk.Anthropic::new(api_key="key", transport, clock))
    assert_eq(clock.slept(), [121000])
    transport.assert_complete()

    // With a total limit the wait that would outlast it is not begun.
    let bounded_call = @mock.FakeTransport::new()
    bounded_call.expect(
      "POST",
      "/v1/messages",
      json_response(
        "{}",
        status=429,
        headers=@http.Headers::from_array([("retry-after", "121")]),
      ),
    )
    let clock = @mock.FakeClock::new()
    let client = @anthropic_sdk.Anthropic::new(
      api_key="key",
      bounded_call,
      clock,
      timer=ScriptedTimer::{ budgets: [], expire: 0, },
      total_timeout_ms=60000,
    )
    try ask(client) catch {
      error => assert_eq(error.status(), Some(429))
    } noraise {
      _ => fail("a wait past the total limit must raise")
    }
    assert_eq(clock.slept(), [])
    bounded_call.assert_complete()
  })
}

///|
async test "a timer limits each attempt to 600 s and a timed-out POST is retried" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("POST", "/v1/messages", json_response(message_ok))
    let timer = ScriptedTimer::{ budgets: [], expire: 1, }
    let clock = @mock.FakeClock::new()
    ask(@anthropic_sdk.Anthropic::new(api_key="key", transport, clock, timer~))
    assert_eq(timer.budgets, [600000, 600000])
    assert_eq(clock.slept().length(), 1)
    transport.assert_complete()

    let timer = ScriptedTimer::{ budgets: [], expire: 3, }
    let idle = @mock.FakeTransport::new()
    try
      ask(
        @anthropic_sdk.Anthropic::new(
          api_key="key",
          idle,
          @mock.FakeClock::new(),
          timer~,
          timeout_ms=1000,
        ),
      )
    catch {
      @runtime.Transport(Timeout(phase=Unknown, ms=1000)) => ()
      _ => fail("expected the attempt timeout")
    } noraise {
      _ => fail("an attempt that never finishes must time out")
    }
    assert_eq(timer.budgets, [1000, 1000, 1000])
    assert_eq(idle.sent().length(), 0)
  })
}
