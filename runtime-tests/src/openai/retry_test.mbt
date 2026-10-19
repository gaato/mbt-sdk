// The official SDK's retries (openai-python `_base_client.py`), which
// `OpenAI::new` adopts by default: see docs/behavior/openai.md.

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
let embeddings_ok : String = "{\"data\":[],\"model\":\"e\",\"usage\":{\"prompt_tokens\":0,\"total_tokens\":0}}"

///|
async fn embed(client : @openai_sdk.OpenAI) -> Unit raise @runtime.SdkError {
  ignore(
    client.create_embeddings(
      @openai_sdk.EmbeddingRequest::new(model="e", input=["x"]),
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
async test "a POST is retried on 5xx twice with the official backoff" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("POST", "/embeddings", json_response("{}", status=500))
    transport.expect("POST", "/embeddings", json_response(embeddings_ok))
    let clock = @mock.FakeClock::new()
    embed(@openai_sdk.OpenAI::new(api_key="key", transport, clock))
    assert_eq(clock.slept().length(), 1)
    assert_stainless_backoff(clock.slept())
    transport.assert_complete()

    let failing = @mock.FakeTransport::new()
    for status in [503, 501, 599] {
      failing.expect("POST", "/embeddings", json_response("{}", status~))
    }
    let clock = @mock.FakeClock::new()
    try embed(@openai_sdk.OpenAI::new(api_key="key", failing, clock)) catch {
      error => assert_eq(error.status(), Some(599))
    } noraise {
      _ => fail("the third 5xx must be raised")
    }
    assert_eq(clock.slept().length(), 2)
    assert_stainless_backoff(clock.slept())
    failing.assert_complete()
  })
}

///|
async test "conservative() keeps a POST from being retried on 5xx" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("POST", "/embeddings", json_response("{}", status=500))
    let clock = @mock.FakeClock::new()
    let client = @openai_sdk.OpenAI::new(
      api_key="key",
      transport,
      clock,
      retry=@runtime.RetryPolicy::conservative(),
    )
    try embed(client) catch {
      error => assert_eq(error.status(), Some(500))
    } noraise {
      _ => fail("500 must be raised")
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
      "/embeddings",
      json_response(
        "{}",
        status=500,
        headers=@http.Headers::from_array([("x-should-retry", "false")]),
      ),
    )
    let clock = @mock.FakeClock::new()
    try embed(@openai_sdk.OpenAI::new(api_key="key", refused, clock)) catch {
      error => assert_eq(error.status(), Some(500))
    } noraise {
      _ => fail("x-should-retry: false must stop")
    }
    assert_eq(clock.slept(), [])
    refused.assert_complete()

    let forced = @mock.FakeTransport::new()
    forced.expect(
      "POST",
      "/embeddings",
      json_response(
        "{}",
        status=400,
        headers=@http.Headers::from_array([("x-should-retry", "true")]),
      ),
    )
    forced.expect("POST", "/embeddings", json_response(embeddings_ok))
    let clock = @mock.FakeClock::new()
    embed(@openai_sdk.OpenAI::new(api_key="key", forced, clock))
    assert_eq(clock.slept().length(), 1)
    forced.assert_complete()
  })
}

///|
async test "a Retry-After over two minutes is not waited for" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/embeddings",
      json_response(
        "{}",
        status=429,
        headers=@http.Headers::from_array([("retry-after", "121")]),
      ),
    )
    let clock = @mock.FakeClock::new()
    try embed(@openai_sdk.OpenAI::new(api_key="key", transport, clock)) catch {
      error => assert_eq(error.status(), Some(429))
    } noraise {
      _ => fail("a 121 s Retry-After must be raised")
    }
    assert_eq(clock.slept(), [])
    transport.assert_complete()

    // Two minutes exactly is waited for.
    let patient = @mock.FakeTransport::new()
    patient.expect(
      "POST",
      "/embeddings",
      json_response(
        "{}",
        status=503,
        headers=@http.Headers::from_array([("retry-after", "120")]),
      ),
    )
    patient.expect("POST", "/embeddings", json_response(embeddings_ok))
    let clock = @mock.FakeClock::new()
    embed(@openai_sdk.OpenAI::new(api_key="key", patient, clock))
    assert_eq(clock.slept(), [120000])
    patient.assert_complete()
  })
}

///|
async test "a timer limits each attempt to 600 s and a timed-out POST is retried" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect("POST", "/embeddings", json_response(embeddings_ok))
    let timer = ScriptedTimer::{ budgets: [], expire: 1, }
    let clock = @mock.FakeClock::new()
    embed(@openai_sdk.OpenAI::new(api_key="key", transport, clock, timer~))
    // The first exchange ran out of time and was retried after a backoff.
    assert_eq(timer.budgets, [600000, 600000])
    assert_eq(clock.slept().length(), 1)
    transport.assert_complete()

    // The total limit caps an attempt's budget; timeout_ms sets it.
    let transport = @mock.FakeTransport::new()
    transport.expect("POST", "/embeddings", json_response(embeddings_ok))
    let timer = ScriptedTimer::{ budgets: [], expire: 0, }
    embed(
      @openai_sdk.OpenAI::new(
        api_key="key",
        transport,
        @mock.FakeClock::new(),
        timer~,
        timeout_ms=30000,
        total_timeout_ms=20000,
      ),
    )
    assert_eq(timer.budgets, [20000])
    transport.assert_complete()

    // Every attempt out of time: the timeout is raised after two retries.
    let timer = ScriptedTimer::{ budgets: [], expire: 3, }
    let idle = @mock.FakeTransport::new()
    try
      embed(
        @openai_sdk.OpenAI::new(
          api_key="key",
          idle,
          @mock.FakeClock::new(),
          timer~,
          timeout_ms=1000,
        ),
      )
    catch {
      @runtime.Transport(Timeout(phase=Unknown, ms=1000)) => ()
      error => fail("expected the attempt timeout: " + @debug.to_string(error))
    } noraise {
      _ => fail("an attempt that never finishes must time out")
    }
    assert_eq(timer.budgets, [1000, 1000, 1000])
    assert_eq(idle.sent().length(), 0)
  })
}
