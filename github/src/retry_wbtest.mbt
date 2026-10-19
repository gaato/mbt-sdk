///|
fn limited(
  status : Int32,
  headers : Array[(String, String)],
  body : String,
) -> @runtime.SdkError {
  let headers = @http.Headers::from_array(headers)
  let body = @utf8.encode(body)
  if status == 429 {
    @runtime.RateLimited(retry_after_ms=None, headers~, body~)
  } else {
    @runtime.Status(status~, headers~, body~)
  }
}

///|
fn github_retry() -> GitHubRetry {
  { policy: @runtime.RetryPolicy::conservative().with_max_retries(3), }
}

///|
test "a secondary limit waits retry-after, else a minute doubling, past the generic cap" {
  let post = @http.Request::post("/repos/o/r/issues")
  let named = limited(
    403,
    [],
    "{\"message\":\"You have exceeded a secondary rate limit.\"}",
  )
  let decisions = [0, 1, 2, 3].map(attempt => {
    github_retry().decide(named, @runtime.RetryContext::new(post, attempt~))
  })
  assert_eq(decisions, [
    Wait(60000),
    Wait(120000),
    Wait(240000),
    Stop(Exhausted),
  ])
  // Retry-After wins, whatever the policy's cap (60 s here).
  let told = limited(429, [("retry-after", "300")], "{}")
  assert_eq(
    github_retry().decide(told, @runtime.RetryContext::new(post)),
    Wait(300000),
  )
  // An HTTP date is read against the attempt's clock.
  let dated = limited(
    403,
    [("retry-after", "Thu, 01 Jan 1970 00:01:30 GMT")],
    "{}",
  )
  assert_eq(
    github_retry().decide(
      dated,
      @runtime.RetryContext::new(post, now_unix_ms=60000L),
    ),
    Wait(30000),
  )
  // Zero falls back to the minute, as octokit's `Number(h) || 60`.
  let zero = limited(403, [("retry-after", "0")], "{}")
  assert_eq(
    github_retry().decide(zero, @runtime.RetryContext::new(post)),
    Wait(60000),
  )
  // The remaining time bounds it.
  assert_eq(
    github_retry().decide(
      named,
      @runtime.RetryContext::new(post, remaining_ms=60000L),
    ),
    Stop(Budget(60000)),
  )
  // A body that cannot be sent again is not.
  assert_eq(
    github_retry().decide(
      named,
      @runtime.RetryContext::new(post, replayable=false),
    ),
    Stop(NotReplayable),
  )
  // The doubling saturates.
  let many : GitHubRetry = {
    policy: @runtime.RetryPolicy::conservative().with_max_retries(100),
  }
  assert_eq(
    many.decide(named, @runtime.RetryContext::new(post, attempt=40)),
    Wait(2147483647),
  )
}

///|
test "a primary limit waits until a second past the reset, once" {
  let get = @http.Request::get("/repos/o/r")
  let spent = limited(
    403,
    [("x-ratelimit-remaining", "0"), ("x-ratelimit-reset", "100")],
    "{\"message\":\"API rate limit exceeded\"}",
  )
  assert_eq(
    github_retry().decide(
      spent,
      @runtime.RetryContext::new(get, now_unix_ms=40500L),
    ),
    Wait(61000),
  )
  assert_eq(
    github_retry().decide(
      spent,
      @runtime.RetryContext::new(get, attempt=1, now_unix_ms=40500L),
    ),
    Stop(Exhausted),
  )
  // A 429 is not handed to the policy's quick 429 retry either.
  let spent_429 = limited(
    429,
    [("x-ratelimit-remaining", "0"), ("x-ratelimit-reset", "100")],
    "{}",
  )
  assert_eq(
    github_retry().decide(
      spent_429,
      @runtime.RetryContext::new(get, attempt=1, now_unix_ms=40500L),
    ),
    Stop(Exhausted),
  )
  assert_eq(
    github_retry().decide(
      spent,
      @runtime.RetryContext::new(get, now_unix_ms=0L, remaining_ms=100000L),
    ),
    Stop(Budget(101000)),
  )
  // Without a reset there is nothing to wait for.
  let unknown = limited(403, [("x-ratelimit-remaining", "0")], "{}")
  assert_eq(
    github_retry().decide(unknown, @runtime.RetryContext::new(get)),
    Stop(NotRetryable),
  )
  // A GraphQL RATE_LIMITED reply is a primary limit too.
  let graphql = limited(
    429,
    [("x-ratelimit-reset", "10")],
    "{\"errors\":[{\"type\":\"RATE_LIMITED\",\"message\":\"API rate limit exceeded\"}]}",
  )
  assert_eq(
    github_retry().decide(
      graphql,
      @runtime.RetryContext::new(get, bucket="graphql"),
    ),
    Wait(11000),
  )
  // Retries disabled means none.
  let none : GitHubRetry = { policy: @runtime.RetryPolicy::none(), }
  assert_eq(
    none.decide(spent, @runtime.RetryContext::new(get)),
    Stop(Exhausted),
  )
}

///|
test "the primary wait rounds up to whole seconds and never goes negative" {
  assert_eq(primary_wait_ms(100L, 100000L), 1000)
  assert_eq(primary_wait_ms(100L, 99999L), 2000)
  assert_eq(primary_wait_ms(100L, 99000L), 2000)
  assert_eq(primary_wait_ms(100L, 100999L), 1000)
  assert_eq(primary_wait_ms(100L, 101000L), 0)
  assert_eq(primary_wait_ms(100L, 500000L), 0)
  assert_eq(primary_wait_ms(1099511627776L, 0L), 2147483647)
  assert_eq(parse_unix_seconds(" 1700000000 "), Some(1700000000L))
  assert_eq(parse_unix_seconds("-1"), None)
  assert_eq(parse_unix_seconds("1.5"), None)
  assert_eq(parse_unix_seconds(""), None)
  assert_eq(parse_unix_seconds("99999999999999999999"), None)
}

///|
test "a transient graphql failure is retried with backoff for queries only" {
  let post = @http.Request::post("/graphql")
  let transient = @runtime.Decode(
    message="graphql: Something went wrong",
    body=@utf8.encode(
      "{\"errors\":[{\"message\":\"Something went wrong while executing your query.\"}]}",
    ),
  )
  let decide = (bucket : String, attempt : Int32) => {
    github_retry().decide(
      transient,
      @runtime.RetryContext::new(post, bucket~, attempt~, random=0.5),
    )
  }
  assert_eq(decide("graphql", 0), Wait(500))
  assert_eq(decide("graphql", 1), Wait(1000))
  assert_eq(decide("graphql", 3), Stop(Exhausted))
  assert_eq(decide("graphql:mutation", 0), Stop(NotRetryable))
  // Another decode failure is never retried.
  let other = @runtime.Decode(
    message="bad",
    body=b"{\"errors\":[{\"message\":\"Field 'x' doesn't exist\"}]}",
  )
  assert_eq(
    github_retry().decide(
      other,
      @runtime.RetryContext::new(post, bucket="graphql"),
    ),
    Stop(NotRetryable),
  )
}

///|
test "everything else is the policy's, cap included" {
  let get = @http.Request::get("/repos/o/r")
  let post = @http.Request::post("/repos/o/r/issues")
  let bad_gateway = limited(502, [], "")
  assert_eq(
    github_retry().decide(bad_gateway, @runtime.RetryContext::new(post)),
    Stop(MethodNotAllowed),
  )
  assert_eq(
    github_retry().decide(bad_gateway, @runtime.RetryContext::new(get)),
    Wait(500),
  )
  // A plain 429 whose wait is over the policy's cap: StopAbove stops,
  // BackoffAbove falls back to the backoff.
  let long = limited(429, [("x-ratelimit-remaining", "10")], "{}")
  let long = match long {
    @runtime.RateLimited(headers~, body~, ..) =>
      @runtime.RateLimited(retry_after_ms=Some(90000), headers~, body~)
    other => other
  }
  assert_eq(
    github_retry().decide(long, @runtime.RetryContext::new(get)),
    Stop(RetryAfterTooLong(90000)),
  )
  let lenient : GitHubRetry = {
    policy: {
      rule: {
        ..@runtime.RetryPolicy::conservative().rule,
        retry_after: {
          ..@runtime.RetryPolicy::conservative().rule.retry_after,
          cap: BackoffAbove(60000),
        },
      },
    },
  }
  assert_eq(lenient.decide(long, @runtime.RetryContext::new(get)), Wait(500))
  let forbidden = limited(403, [], "{\"message\":\"Resource not accessible\"}")
  assert_eq(
    github_retry().decide(forbidden, @runtime.RetryContext::new(get)),
    Stop(NotRetryable),
  )
}
