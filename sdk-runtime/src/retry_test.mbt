///|
fn status_error(
  status : Int32,
  headers~ : @http.Headers = @http.Headers::new(),
) -> @runtime.SdkError {
  @runtime.Status(status~, headers~, body=b"")
}

///|
fn rate_limited(
  retry_after_ms : Int32?,
  headers~ : @http.Headers = @http.Headers::new(),
) -> @runtime.SdkError {
  @runtime.RateLimited(retry_after_ms~, headers~, body=b"")
}

///|
fn transport_error(error : @http.HttpError) -> @runtime.SdkError {
  @runtime.Transport(error)
}

///|
test "RetryPolicy presets are the documented rules" {
  let conservative : @runtime.RetryPolicy = {
    rule: {
      max_retries: 2,
      statuses: [
        { statuses: [Code(429)], methods: Any, },
        {
          statuses: [
            Code(408),
            Code(409),
            Code(500),
            Code(502),
            Code(503),
            Code(504),
          ],
          methods: Idempotent,
        },
      ],
      sent_failures: Idempotent,
      unsent_failures: true,
      override_header: None,
      retry_after: {
        source: MsThenHeader,
        cap: StopAbove(60000),
        zero_means_backoff: false,
      },
      backoff: {
        base_ms: 500,
        max_ms: 30000,
        jitter: Proportional(lo=800, hi=1200),
      },
    },
  }
  assert_eq(@runtime.RetryPolicy::conservative(), conservative)
  assert_eq(@runtime.RetryPolicy::default(), conservative)
  assert_eq(@runtime.RetryPolicy::none(), {
    rule: { ..conservative.rule, max_retries: 0, },
  })
  assert_eq(
    @runtime.RetryPolicy::from_rule(conservative.rule).with_max_retries(5).rule.max_retries,
    5,
  )
  let caps : Array[@runtime.RetryAfterCap] = [StopAbove(120000), NoCap]
  for cap in caps {
    let stainless : @runtime.RetryPolicy = {
      rule: {
        max_retries: 2,
        statuses: [
          {
            statuses: [Code(408), Code(409), Code(429), Range(500, 599)],
            methods: Any,
          },
        ],
        sent_failures: Any,
        unsent_failures: true,
        override_header: Some("x-should-retry"),
        retry_after: { source: MsThenHeader, cap, zero_means_backoff: true, },
        backoff: {
          base_ms: 500,
          max_ms: 8000,
          jitter: Proportional(lo=750, hi=1000),
        },
      },
    }
    assert_eq(@runtime.RetryPolicy::stainless(cap~), stainless)
  }
  let widened = conservative.allow_non_idempotent()
  assert_eq(widened.rule.sent_failures, Any)
  assert_eq(widened.rule.statuses.map(rule => rule.methods), [Any, Any])
  assert_eq(
    widened.rule.statuses[1].statuses,
    conservative.rule.statuses[1].statuses,
  )
  let listed = @runtime.RetryPolicy::from_rule({
    ..conservative.rule,
    statuses: [{ statuses: [Code(503)], methods: Listed(["PUT"]), }],
    sent_failures: Never,
  }).allow_non_idempotent()
  assert_eq(listed.rule.statuses[0].methods, Listed(["PUT"]))
  assert_eq(listed.rule.sent_failures, Never)
}

///|
/// Every `SdkError` shape against conservative() for GET, POST and a POST with
/// an idempotency key, at the first failure with random 0.0 (backoff 400 ms).
test "conservative decides every SdkError variant by method" {
  let policy = @runtime.RetryPolicy::conservative()
  let get = @http.Request::get("/")
  let post = @http.Request::post("/")
  let keyed_post = post.header("idempotency-key", "key")
  let wait : @runtime.Decision = Wait(400)
  let not_retryable : @runtime.Decision = Stop(NotRetryable)
  let refused : @runtime.Decision = Stop(MethodNotAllowed)
  let cases : Array[(@runtime.SdkError, @runtime.Decision, @runtime.Decision)] = [
    // A failure that proves nothing was sent is retried for any method.
    (transport_error(Connect("offline")), wait, wait),
    (transport_error(Timeout(phase=Pool, ms=1)), wait, wait),
    (transport_error(Timeout(phase=Dial, ms=1)), wait, wait),
    // One after sending only for an idempotent request.
    (transport_error(Timeout(phase=Write, ms=1)), wait, refused),
    (transport_error(Timeout(phase=Head, ms=1)), wait, refused),
    (transport_error(Timeout(phase=Body, ms=1)), wait, refused),
    (transport_error(Timeout(phase=Unknown, ms=1)), wait, refused),
    (transport_error(Network(phase=Write, message="")), wait, refused),
    (transport_error(Network(phase=Head, message="")), wait, refused),
    (transport_error(Network(phase=Body, message="")), wait, refused),
    (transport_error(Network(phase=Unknown, message="")), wait, refused),
    (transport_error(Protocol("bad")), not_retryable, not_retryable),
    // A proxy's refusal when its status is in a rule, for any method.
    (transport_error(Proxy(status=502, message="")), wait, wait),
    (transport_error(Proxy(status=503, message="")), wait, wait),
    (transport_error(Proxy(status=504, message="")), wait, wait),
    (transport_error(Proxy(status=500, message="")), wait, wait),
    (transport_error(Proxy(status=429, message="")), wait, wait),
    (
      transport_error(Proxy(status=407, message="")),
      not_retryable,
      not_retryable,
    ),
    (
      transport_error(Proxy(status=403, message="")),
      not_retryable,
      not_retryable,
    ),
    (status_error(408), wait, refused),
    (status_error(409), wait, refused),
    (status_error(500), wait, refused),
    (status_error(502), wait, refused),
    (status_error(503), wait, refused),
    (status_error(504), wait, refused),
    (status_error(429), wait, wait),
    (status_error(400), not_retryable, not_retryable),
    (status_error(501), not_retryable, not_retryable),
    (status_error(505), not_retryable, not_retryable),
    (rate_limited(None), wait, wait),
    (@runtime.Decode(message="bad", body=b""), not_retryable, not_retryable),
    (@runtime.Config("bad"), not_retryable, not_retryable),
  ]
  for i, case in cases {
    let (error, idempotent, non_idempotent) = case
    let decide = (request, attempt) => {
      policy.decide(
        error,
        @runtime.RetryContext::new(request, attempt~, random=0.0),
      )
    }
    assert_eq(decide(get, 0), idempotent, msg="row \{i} GET")
    assert_eq(decide(keyed_post, 0), idempotent, msg="row \{i} keyed POST")
    assert_eq(decide(post, 0), non_idempotent, msg="row \{i} POST")
    // is_retryable is the classification conservative() applies to GET.
    assert_eq(error.is_retryable(), idempotent is Wait(_), msg="row \{i}")
    let exhausted : @runtime.Decision = if error.outcome() is Some(_) {
      Stop(Exhausted)
    } else {
      not_retryable
    }
    assert_eq(decide(get, 2), exhausted, msg="row \{i} exhausted")
    assert_eq(
      @runtime.RetryPolicy::none().decide(
        error,
        @runtime.RetryContext::new(get),
      ),
      exhausted,
      msg="row \{i} none",
    )
  }
  let widened = policy.allow_non_idempotent()
  assert_eq(
    widened.decide(
      transport_error(Timeout(phase=Head, ms=1)),
      @runtime.RetryContext::new(post, random=0.0),
    ),
    wait,
  )
  assert_eq(
    widened.decide(
      status_error(503),
      @runtime.RetryContext::new(post, random=0.0),
    ),
    wait,
  )
}

///|
/// The same table against stainless(): no method restrictions, every 5xx,
/// backoff 375 ms at random 0.0.
test "stainless decides every SdkError variant for any method" {
  let policy = @runtime.RetryPolicy::stainless(cap=StopAbove(120000))
  let wait : @runtime.Decision = Wait(375)
  let not_retryable : @runtime.Decision = Stop(NotRetryable)
  let cases : Array[(@runtime.SdkError, @runtime.Decision)] = [
    (transport_error(Connect("offline")), wait),
    (transport_error(Timeout(phase=Pool, ms=1)), wait),
    (transport_error(Timeout(phase=Dial, ms=1)), wait),
    (transport_error(Timeout(phase=Write, ms=1)), wait),
    (transport_error(Timeout(phase=Head, ms=1)), wait),
    (transport_error(Timeout(phase=Body, ms=1)), wait),
    (transport_error(Timeout(phase=Unknown, ms=1)), wait),
    (transport_error(Network(phase=Write, message="")), wait),
    (transport_error(Network(phase=Unknown, message="")), wait),
    (transport_error(Protocol("bad")), not_retryable),
    (transport_error(Proxy(status=502, message="")), wait),
    (transport_error(Proxy(status=407, message="")), not_retryable),
    (status_error(408), wait),
    (status_error(409), wait),
    (status_error(429), wait),
    (status_error(500), wait),
    (status_error(501), wait),
    (status_error(529), wait),
    (status_error(599), wait),
    (status_error(400), not_retryable),
    (status_error(404), not_retryable),
    (rate_limited(None), wait),
    (@runtime.Decode(message="bad", body=b""), not_retryable),
    (@runtime.Config("bad"), not_retryable),
  ]
  for i, case in cases {
    let (error, expected) = case
    for request in [@http.Request::get("/"), @http.Request::post("/")] {
      assert_eq(
        policy.decide(error, @runtime.RetryContext::new(request, random=0.0)),
        expected,
        msg="row \{i} \{request.http_method}",
      )
    }
  }
  // x-should-retry overrides the status rules both ways.
  let post = @http.Request::post("/")
  let yes = @http.Headers::from_array([("x-should-retry", "true")])
  let no = @http.Headers::from_array([("x-should-retry", "false")])
  let context = @runtime.RetryContext::new(post, random=0.0)
  assert_eq(policy.decide(status_error(400, headers=yes), context), wait)
  assert_eq(
    policy.decide(status_error(500, headers=no), context),
    Stop(ServerSaidNo),
  )
  assert_eq(
    policy.decide(rate_limited(None, headers=no), context),
    Stop(ServerSaidNo),
  )
  // Backoff: 500 ms doubling to 8 s, shortened by up to 25 %.
  let delays = [0, 1, 2, 3, 4, 10].map(attempt => {
    policy.rule.backoff.delay_ms(attempt, 0.0)
  })
  assert_eq(delays, [375, 750, 1500, 3000, 6000, 6000])
  assert_eq(policy.rule.backoff.delay_ms(4, 0.999), 7992)
}

///|
test "server delays: sources, caps, zero and HTTP dates" {
  let request = @http.Request::get("/")
  let context = @runtime.RetryContext::new(request, random=0.0)
  let policy = @runtime.RetryPolicy::from_rule({
    ..@runtime.RetryPolicy::conservative().rule,
    retry_after: {
      source: MsThenHeader,
      cap: StopAbove(1500),
      zero_means_backoff: false,
    },
  })
  let cases : Array[(@runtime.SdkError, @runtime.Decision)] = [
    (rate_limited(Some(0)), Wait(0)),
    (rate_limited(Some(1500)), Wait(1500)),
    (rate_limited(Some(1501)), Stop(RetryAfterTooLong(1501))),
    (
      status_error(
        503,
        headers=@http.Headers::from_array([("retry-after", "1.5")]),
      ),
      Wait(1500),
    ),
    (
      status_error(
        503,
        headers=@http.Headers::from_array([("retry-after-ms", "1501")]),
      ),
      Stop(RetryAfterTooLong(1501)),
    ),
    (
      status_error(
        503,
        headers=@http.Headers::from_array([("retry-after", "bad")]),
      ),
      Wait(400),
    ),
  ]
  for i, case in cases {
    assert_eq(policy.decide(case.0, context), case.1, msg="row \{i}")
  }
  // An HTTP date needs the context's clock: before 0.7.0 a Status ignored it.
  let dated = status_error(
    503,
    headers=@http.Headers::from_array([
      ("retry-after", "Thu, 01 Jan 1970 00:00:02 GMT"),
    ]),
  )
  assert_eq(
    @runtime.RetryPolicy::conservative().decide(
      dated,
      @runtime.RetryContext::new(request, now_unix_ms=500L),
    ),
    Wait(1500),
  )
  // Stainless treats 0 as "no delay given"; the cap decides long delays.
  let zero = rate_limited(Some(0))
  assert_eq(
    @runtime.RetryPolicy::stainless(cap=NoCap).decide(zero, context),
    Wait(375),
  )
  let long = rate_limited(Some(600000))
  assert_eq(
    @runtime.RetryPolicy::stainless(cap=StopAbove(120000)).decide(long, context),
    Stop(RetryAfterTooLong(600000)),
  )
  assert_eq(
    @runtime.RetryPolicy::stainless(cap=NoCap).decide(long, context),
    Wait(600000),
  )
  // A rule that ignores server delays ignores a parsed retry_after_ms too.
  let ignoring = @runtime.RetryPolicy::from_rule({
    ..policy.rule,
    retry_after: { ..policy.rule.retry_after, source: Ignore, },
  })
  assert_eq(ignoring.decide(rate_limited(Some(1200)), context), Wait(400))
}

///|
test "the context's remaining time and replayability stop a retry" {
  let get = @http.Request::get("/")
  let policy = @runtime.RetryPolicy::conservative()
  let error = status_error(503)
  assert_eq(
    policy.decide(
      error,
      @runtime.RetryContext::new(get, random=0.0, remaining_ms=401L),
    ),
    Wait(400),
  )
  assert_eq(
    policy.decide(
      error,
      @runtime.RetryContext::new(get, random=0.0, remaining_ms=400L),
    ),
    Stop(Budget(400)),
  )
  assert_eq(
    policy.decide(error, @runtime.RetryContext::new(get, replayable=false)),
    Stop(NotReplayable),
  )
  let context = @runtime.RetryContext::new(
    get,
    bucket="b",
    attempt=1,
    random=0.25,
    now_unix_ms=7L,
  )
  assert_eq(
    (
      context.bucket,
      context.attempt,
      context.random,
      context.now_unix_ms,
      context.remaining_ms,
      context.replayable,
    ),
    ("b", 1, 0.25, 7L, None, true),
  )
}
