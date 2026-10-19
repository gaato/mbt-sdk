///|
// Backoff without jitter: 100, 200, 400, ... ms, so every wait is exact.
fn rule() -> @retry.RetryRule {
  {
    max_retries: 3,
    statuses: [
      { statuses: [Code(429)], methods: Any, },
      { statuses: [Code(408), Range(500, 599)], methods: Idempotent, },
      { statuses: [Code(409)], methods: Listed(["put", "Patch"]), },
      { statuses: [Code(418)], methods: Never, },
    ],
    sent_failures: Idempotent,
    unsent_failures: true,
    override_header: Some("x-should-retry"),
    retry_after: {
      source: MsThenHeader,
      cap: NoCap,
      zero_means_backoff: false,
    },
    backoff: { base_ms: 100, max_ms: 1000, jitter: NoJitter, },
  }
}

///|
fn response(status : Int32, pairs : Array[(String, String)]) -> @retry.Outcome {
  Response(status~, headers=@http.Headers::from_array(pairs))
}

///|
struct Empty {}

///|
impl @http.BodyStream for Empty with fn read_some(_) {
  None
}

///|
impl @http.BodyStream for Empty with fn close(_) {
  ()
}

///|
test "decide covers every step in order" {
  let r = rule()
  let get = @http.Request::get("/")
  let post = @http.Request::post("/")
  let keyed = post.header("Idempotency-Key", "k-1")
  let fresh_stream = post.body_stream(Empty::{ })
  let sent_stream = post.body_stream(Empty::{ })
  if sent_stream.body is Stream(stream) {
    stream.take().close()
  }
  let s503 = response(503, [])
  let date = "Sun, 06 Nov 1994 08:49:37 GMT"
  let date_ms = 784111777000L
  let cases : Array[(String, @retry.Decision, @retry.Decision)] = [
    // 1. Exhausted
    ("first failure", r.decide(s503, get, attempt=0, random=0.0), Wait(100)),
    ("last retry", r.decide(s503, get, attempt=2, random=0.0), Wait(400)),
    ("exhausted", r.decide(s503, get, attempt=3, random=0.0), Stop(Exhausted)),
    (
      "exhausted before replayable",
      r.decide(s503, get, attempt=3, random=0.0, replayable=false),
      Stop(Exhausted),
    ),
    (
      "exhausted before override",
      r.decide(
        response(503, [("x-should-retry", "true")]),
        get,
        attempt=4,
        random=0.0,
      ),
      Stop(Exhausted),
    ),
    (
      "never retries",
      @retry.RetryRule::never().decide(s503, get, attempt=0, random=0.0),
      Stop(Exhausted),
    ),
    // 2. Replayable
    (
      "replayable param false",
      r.decide(s503, get, attempt=0, random=0.0, replayable=false),
      Stop(NotReplayable),
    ),
    (
      "sent stream body",
      r.decide(response(429, []), sent_stream, attempt=0, random=0.0),
      Stop(NotReplayable),
    ),
    (
      "untaken stream body",
      r.decide(response(429, []), fresh_stream, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "replayable param true overrides",
      r.decide(
        response(429, []),
        sent_stream,
        attempt=0,
        random=0.0,
        replayable=true,
      ),
      Wait(100),
    ),
    (
      "replayable before override",
      r.decide(
        response(503, [("x-should-retry", "true")]),
        get,
        attempt=0,
        random=0.0,
        replayable=false,
      ),
      Stop(NotReplayable),
    ),
    // 3. Override header
    (
      "override true retries a 200 POST",
      r.decide(
        response(200, [("X-Should-Retry", " TRUE ")]),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "override true retries a forbidden method",
      r.decide(
        response(418, [("x-should-retry", "true")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "override false stops a retryable status",
      r.decide(
        response(429, [("x-should-retry", "False")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(ServerSaidNo),
    ),
    (
      "override garbage is ignored: retryable",
      r.decide(
        response(503, [("x-should-retry", "maybe")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "override garbage is ignored: not retryable",
      r.decide(
        response(200, [("x-should-retry", "1")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "no override header configured",
      { ..r, override_header: None, }.decide(
        response(200, [("x-should-retry", "true")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    // 4. Statuses and methods
    (
      "429 any method",
      r.decide(response(429, []), post, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "408 code idempotent",
      r.decide(response(408, []), get, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "range low bound",
      r.decide(response(500, []), get, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "range high bound",
      r.decide(response(599, []), get, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "below range",
      r.decide(response(499, []), get, attempt=0, random=0.0),
      Stop(NotRetryable),
    ),
    (
      "above range",
      r.decide(response(600, []), get, attempt=0, random=0.0),
      Stop(NotRetryable),
    ),
    (
      "503 POST not idempotent",
      r.decide(s503, post, attempt=0, random=0.0),
      Stop(MethodNotAllowed),
    ),
    (
      "503 POST with idempotency key",
      r.decide(s503, keyed, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "idempotent param true for POST",
      r.decide(s503, post, attempt=0, random=0.0, idempotent=true),
      Wait(100),
    ),
    (
      "idempotent param false for GET",
      r.decide(s503, get, attempt=0, random=0.0, idempotent=false),
      Stop(MethodNotAllowed),
    ),
    (
      "listed method",
      r.decide(
        response(409, []),
        @http.Request::put("/"),
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "listed ignores case",
      r.decide(
        response(409, []),
        @http.Request::new("pAtCh", "/"),
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "unlisted method",
      r.decide(response(409, []), post, attempt=0, random=0.0),
      Stop(MethodNotAllowed),
    ),
    (
      "never methods",
      r.decide(response(418, []), get, attempt=0, random=0.0),
      Stop(MethodNotAllowed),
    ),
    // 4. Failures
    (
      "protocol never",
      r.decide(Failure(Protocol("bad")), get, attempt=0, random=0.0),
      Stop(NotRetryable),
    ),
    (
      "connect any method",
      r.decide(Failure(Connect("refused")), post, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "pool timeout any method",
      r.decide(Failure(Timeout(phase=Pool, ms=10)), post, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "dial timeout any method",
      r.decide(Failure(Timeout(phase=Dial, ms=10)), post, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "unsent failures off",
      { ..r, unsent_failures: false, }.decide(
        Failure(Connect("refused")),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "proxy status matches a rule, method ignored",
      r.decide(
        Failure(Proxy(status=502, message="bad gateway")),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "proxy status matches no rule",
      r.decide(
        Failure(Proxy(status=407, message="auth")),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "proxy with unsent failures off",
      { ..r, unsent_failures: false, }.decide(
        Failure(Proxy(status=502, message="bad gateway")),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "head timeout idempotent",
      r.decide(Failure(Timeout(phase=Head, ms=10)), get, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "head timeout POST",
      r.decide(Failure(Timeout(phase=Head, ms=10)), post, attempt=0, random=0.0),
      Stop(MethodNotAllowed),
    ),
    (
      "network POST declared idempotent",
      r.decide(
        Failure(Network(phase=Write, message="reset")),
        post,
        attempt=0,
        random=0.0,
        idempotent=true,
      ),
      Wait(100),
    ),
    (
      "network keyed POST",
      r.decide(
        Failure(Network(phase=Body, message="reset")),
        keyed,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "sent failures never",
      { ..r, sent_failures: Never, }.decide(
        Failure(Timeout(phase=Unknown, ms=10)),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "sent failures any",
      { ..r, sent_failures: Any, }.decide(
        Failure(Network(phase=Head, message="reset")),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "sent failures listed",
      { ..r, sent_failures: Listed(["POST"]), }.decide(
        Failure(Network(phase=Head, message="reset")),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "sent failures listed, other method",
      { ..r, sent_failures: Listed(["POST"]), }.decide(
        Failure(Network(phase=Head, message="reset")),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(MethodNotAllowed),
    ),
    // 5. Server delay
    (
      "retry-after-ms first",
      r.decide(
        response(429, [("retry-after-ms", "1500"), ("retry-after", "9")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(1500),
    ),
    (
      "retry-after seconds",
      r.decide(
        response(429, [("retry-after", "2")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(2000),
    ),
    (
      "header source reads only retry-after",
      {
        ..r,
        retry_after: { source: Header, cap: NoCap, zero_means_backoff: false, },
      }.decide(
        response(429, [("retry-after-ms", "1500")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "header source seconds",
      {
        ..r,
        retry_after: { source: Header, cap: NoCap, zero_means_backoff: false, },
      }.decide(
        response(429, [("retry-after", "2.5")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(2500),
    ),
    (
      "header source date with now",
      {
        ..r,
        retry_after: { source: Header, cap: NoCap, zero_means_backoff: false, },
      }.decide(
        response(429, [("retry-after", date)]),
        get,
        attempt=0,
        random=0.0,
        now_unix_ms=date_ms - 5000L,
      ),
      Wait(5000),
    ),
    (
      "http date with now",
      r.decide(
        response(429, [("retry-after", date)]),
        get,
        attempt=0,
        random=0.0,
        now_unix_ms=date_ms - 7000L,
      ),
      Wait(7000),
    ),
    (
      "http date without now uses backoff",
      r.decide(
        response(429, [("retry-after", date)]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "ignored source uses backoff",
      {
        ..r,
        retry_after: { source: Ignore, cap: NoCap, zero_means_backoff: false, },
      }.decide(
        response(429, [("retry-after", "2")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "zero means now",
      r.decide(
        response(429, [("retry-after", "0")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(0),
    ),
    (
      "zero means backoff",
      {
        ..r,
        retry_after: {
          source: MsThenHeader,
          cap: NoCap,
          zero_means_backoff: true,
        },
      }.decide(
        response(429, [("retry-after", "0")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "stop cap at the limit",
      {
        ..r,
        retry_after: {
          source: MsThenHeader,
          cap: StopAbove(1000),
          zero_means_backoff: false,
        },
      }.decide(
        response(429, [("retry-after-ms", "1000")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(1000),
    ),
    (
      "stop cap over the limit",
      {
        ..r,
        retry_after: {
          source: MsThenHeader,
          cap: StopAbove(1000),
          zero_means_backoff: false,
        },
      }.decide(
        response(429, [("retry-after-ms", "1001")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(RetryAfterTooLong(1001)),
    ),
    (
      "fallback cap at the limit",
      {
        ..r,
        retry_after: {
          source: MsThenHeader,
          cap: BackoffAbove(1000),
          zero_means_backoff: false,
        },
      }.decide(
        response(429, [("retry-after-ms", "1000")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(1000),
    ),
    (
      "fallback cap over the limit",
      {
        ..r,
        retry_after: {
          source: MsThenHeader,
          cap: BackoffAbove(1000),
          zero_means_backoff: false,
        },
      }.decide(
        response(429, [("retry-after", "60")]),
        get,
        attempt=2,
        random=0.0,
      ),
      Wait(400),
    ),
    (
      "no cap",
      r.decide(
        response(429, [("retry-after", "3600")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(3600000),
    ),
    (
      "server delay param wins over headers",
      r.decide(
        response(429, [("retry-after", "2")]),
        get,
        attempt=0,
        random=0.0,
        server_delay_ms=750,
      ),
      Wait(750),
    ),
    (
      "server delay param applies to failures",
      r.decide(
        Failure(Connect("refused")),
        get,
        attempt=0,
        random=0.0,
        server_delay_ms=750,
      ),
      Wait(750),
    ),
    (
      "failures have no server delay",
      r.decide(Failure(Connect("refused")), get, attempt=2, random=0.0),
      Wait(400),
    ),
    (
      "negative server delay counts as zero",
      r.decide(s503, get, attempt=0, random=0.0, server_delay_ms=-5),
      Wait(0),
    ),
    (
      "server delay param zero means backoff",
      {
        ..r,
        retry_after: {
          source: MsThenHeader,
          cap: NoCap,
          zero_means_backoff: true,
        },
      }.decide(s503, get, attempt=1, random=0.0, server_delay_ms=0),
      Wait(200),
    ),
    (
      "server delay param is capped",
      {
        ..r,
        retry_after: {
          source: MsThenHeader,
          cap: StopAbove(500),
          zero_means_backoff: false,
        },
      }.decide(s503, get, attempt=0, random=0.0, server_delay_ms=750),
      Stop(RetryAfterTooLong(750)),
    ),
    // 7. Budget
    (
      "wait equal to budget stops",
      r.decide(s503, get, attempt=2, random=0.0, remaining_ms=400L),
      Stop(Budget(400)),
    ),
    (
      "wait under budget",
      r.decide(s503, get, attempt=2, random=0.0, remaining_ms=401L),
      Wait(400),
    ),
    (
      "server delay over budget",
      r.decide(
        response(429, [("retry-after", "2")]),
        get,
        attempt=0,
        random=0.0,
        remaining_ms=1000L,
      ),
      Stop(Budget(2000)),
    ),
    (
      "spent budget stops even a zero wait",
      r.decide(
        s503,
        get,
        attempt=0,
        random=0.0,
        server_delay_ms=0,
        remaining_ms=0L,
      ),
      Stop(Budget(0)),
    ),
  ]
  for case in cases {
    let (name, actual, expected) = case
    assert_eq(actual, expected, msg=name)
  }
}

///|
test "decide passes random to the backoff" {
  let r = {
    ..rule(),
    backoff: { base_ms: 1000, max_ms: 30000, jitter: Full, },
  }
  let get = @http.Request::get("/")
  assert_eq(r.decide(response(503, []), get, attempt=1, random=0.25), Wait(500))
}

///|
test "outcome debug representation" {
  let outcome = @retry.Failure(@http.Connect("refused"))
  debug_inspect(outcome, content="Failure(Connect(\"refused\"))")
}
