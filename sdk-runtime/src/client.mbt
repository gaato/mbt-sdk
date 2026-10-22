///|
/// A transport-independent SDK client with authentication, retry, and limits.
pub struct Client {
  priv transport : &@http.Transport
  priv clock : &@clock.Clock
  priv base_url : String
  priv default_headers : @http.Headers
  priv auth : Auth
  priv retry : &RetryDecider
  priv limiter : &RateLimiter
  priv middleware : Array[@http.Middleware]
  priv observer : (Attempt) -> Unit
  priv random : () -> Double
  priv timeouts : Timeouts?
}

///|
/// Time limits for `Client` calls, enforced with an injected `@sync.Timer`
/// (such as `gaato/http-async`'s `ClockTimer`), since this module has no
/// async runtime of its own.
///
/// `attempt_ms` bounds each attempt's exchange with the transport: for
/// `send` and `send_json` the whole response, for `send_stream` the response
/// head only (the body belongs to the caller). An exchange that runs out
/// fails with `Transport(Timeout(phase=Unknown, ms=<its limit>))`, which is
/// released, observed and given to the retry decider like any transport
/// failure; under the presets a timeout is a failure after sending, so
/// `conservative()` retries it only for an idempotent request.
///
/// `total_ms` bounds a whole call from when it starts, retries and their
/// waits included. Each exchange is also limited to the time left, the
/// decider is told the time left (`RetryContext::remaining_ms`) so a
/// `RetryPolicy` stops instead of waiting past the end (`Budget`), and an
/// attempt that would start with no time left fails with
/// `Transport(Timeout(phase=Unknown, ms=total_ms))` without asking the
/// decider. Waiting for the rate limiter counts against the total but is
/// not interrupted, so that every admission is paired with its release; a
/// limiter wait can therefore overrun the total by up to its own length.
///
/// A limit that is not positive fails at once: `attempt_ms` every attempt,
/// `total_ms` the call before anything is sent.
pub(all) struct Timeouts {
  /// The timer that cancels an exchange that runs out of time.
  timer : &@sync.Timer
  /// The limit on each attempt's exchange, in milliseconds.
  attempt_ms : Int32?
  /// The limit on a whole call, in milliseconds.
  total_ms : Int32?
}

///|
/// Time limits on `timer`; an omitted limit does not apply.
pub fn Timeouts::new(
  timer : &@sync.Timer,
  attempt_ms? : Int32,
  total_ms? : Int32,
) -> Timeouts {
  { timer, attempt_ms, total_ms, }
}

///|
/// One network attempt of a `Client` call, as reported to the observer.
///
/// `status`, `headers` and `body` are those of the response (the body is empty
/// for a streaming response, whose body belongs to the caller); an attempt
/// that produced no response (a transport failure or a cancellation) reports
/// status `0`, empty headers and body, and the failure in `error` when there
/// is one. `attempt` counts from `0`, so a request that succeeded after two
/// retries reports its last attempt as `2`.
pub(all) struct Attempt {
  bucket : String
  request : @http.Request
  attempt : Int32
  status : Int32
  headers : @http.Headers
  body : Bytes
  duration_ms : Int64
  error : SdkError?
}

///|
/// Creates a client from injected transport and clock implementations.
///
/// `retry` decides after each failed attempt whether to send again; the
/// default is `RetryPolicy::default()`. `observer` is called once per attempt,
/// after the limiter's `release` and before that decision, including for an
/// attempt that fails or is cancelled; it must not raise and should return
/// promptly. `timeouts` limits each attempt and each call (see `Timeouts`);
/// without it nothing is limited here, and only the transport's own timeouts
/// apply.
pub fn Client::new(
  transport : &@http.Transport,
  clock : &@clock.Clock,
  base_url~ : String,
  default_headers? : @http.Headers,
  auth? : Auth,
  retry? : &RetryDecider,
  limiter? : &RateLimiter,
  middleware? : Array[@http.Middleware],
  observer? : (Attempt) -> Unit,
  random? : () -> Double,
  timeouts? : Timeouts,
) -> Client {
  let default_headers = default_headers
    .map(copy_headers)
    .unwrap_or_else(@http.Headers::new)
  let no_limiter : &RateLimiter = NoLimiter::new()
  let default_retry : &RetryDecider = RetryPolicy::default()
  {
    transport,
    clock,
    base_url,
    default_headers,
    auth: auth.unwrap_or(NoAuth),
    retry: retry.unwrap_or(default_retry),
    limiter: limiter.unwrap_or(no_limiter),
    middleware: middleware.map(Array::copy).unwrap_or([]),
    observer: observer.unwrap_or(_ => ()),
    random: random.unwrap_or(@random.default_random),
    timeouts,
  }
}

///|
/// Sends a buffered request, retrying only as directed by the retry decider.
/// A request whose stream body (`Request::body_stream`) a transport has read
/// is never sent again, whatever the decider says: the failure is raised.
///
/// `bucket` names the rate-limit bucket the request is admitted through and
/// `global_exempt` keeps it out of an account-wide limit; both are passed to
/// the limiter as they are.
///
/// `body`, when given, replaces the request's body: it is called once per
/// attempt, after the limiter admits that attempt, so a request waiting for
/// admission holds no encoded body (a multipart upload can keep only the
/// segments from `@multipart.encode_segments` and join them here). The retry
/// decider sees the request without it; the observer sees what was sent.
///
/// `accept`, when given, inspects each successful (2xx) response and may
/// raise to reject it, for an API that reports failures such as rate limits
/// in a successful response. It runs inside the attempt, after the observer
/// has seen the response: what it raises is retried or raised as the retry
/// decider says, exactly like an error status.
pub async fn Client::send(
  self : Client,
  request : @http.Request,
  bucket? : String,
  global_exempt~ : Bool = false,
  body? : () -> Bytes,
  accept? : (@http.Response) -> Unit raise SdkError,
) -> @http.Response raise SdkError {
  let request = self.prepare(request)
  let bucket = bucket.unwrap_or("")
  let deadline = self.deadline()
  for attempt = 0; ; attempt = attempt + 1 {
    self.check_deadline(deadline)
    let outcome : Result[@http.Response, SdkError] = try {
      let response = self.send_once(
        request, body, bucket, global_exempt, attempt, deadline,
      )
      if accept is Some(accept) {
        accept(response)
      }
      response
    } catch {
      error => Err(error)
    } noraise {
      response => Ok(response)
    }
    match outcome {
      Ok(response) => return response
      Err(error) =>
        match
          self.retry_decision(
            error,
            request,
            body is Some(_),
            bucket,
            attempt,
            deadline,
          ) {
          Wait(delay) => self.clock.sleep(delay)
          Stop(_) => raise error
        }
    }
  }
}

///|
/// Sends and decodes JSON; an empty successful body is JSON null. `body` and
/// `accept` are as for `send`.
pub async fn Client::send_json(
  self : Client,
  request : @http.Request,
  bucket? : String,
  global_exempt~ : Bool = false,
  body? : () -> Bytes,
  accept? : (@http.Response) -> Unit raise SdkError,
) -> Json raise SdkError {
  let response = self.send(request, bucket?, global_exempt~, body?, accept?)
  if response.body.is_empty() {
    return Json::null()
  }
  response.json() catch {
    error => raise Decode(message=error.to_string(), body=response.body)
  }
}

///|
/// Sends a streaming request. A successful body is returned to the caller;
/// an unsuccessful body is read up to 1 MiB, closed, classified, and retried.
/// `body`, and a stream request body, are as for `send`.
pub async fn Client::send_stream(
  self : Client,
  request : @http.Request,
  bucket? : String,
  global_exempt~ : Bool = false,
  body? : () -> Bytes,
) -> (@http.ResponseHead, &@http.BodyStream) raise SdkError {
  let request = self.prepare(request)
  let bucket = bucket.unwrap_or("")
  let deadline = self.deadline()
  for attempt = 0; ; attempt = attempt + 1 {
    self.check_deadline(deadline)
    let outcome : Result[(@http.ResponseHead, &@http.BodyStream), SdkError] = Ok(
      self.send_stream_once(
        request, body, bucket, global_exempt, attempt, deadline,
      ),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(response) => return response
      Err(error) =>
        match
          self.retry_decision(
            error,
            request,
            body is Some(_),
            bucket,
            attempt,
            deadline,
          ) {
          Wait(delay) => self.clock.sleep(delay)
          Stop(_) => raise error
        }
    }
  }
}

///|
/// When the call must end, in Unix milliseconds, and the total limit it
/// comes from: `None` without `Timeouts.total_ms`.
fn Client::deadline(self : Client) -> (Int64, Int32)? {
  guard self.timeouts is Some({ total_ms: Some(total_ms), .. }) else {
    return None
  }
  Some((self.clock.now_unix_ms() + total_ms.to_int64(), total_ms))
}

///|
/// Raises the total timeout when no time is left for another attempt.
fn Client::check_deadline(
  self : Client,
  deadline : (Int64, Int32)?,
) -> Unit raise SdkError {
  if deadline is Some((at, total_ms)) && self.clock.now_unix_ms() >= at {
    raise Transport(Timeout(phase=Unknown, ms=total_ms))
  }
}

///|
/// The limit on one exchange: the smaller of `Timeouts.attempt_ms` and the
/// time left before the deadline, of those that are set.
fn Client::attempt_budget(self : Client, deadline : (Int64, Int32)?) -> Int32? {
  guard self.timeouts is Some(timeouts) else { return None }
  let remaining = deadline.map(deadline => {
    let left = deadline.0 - self.clock.now_unix_ms()
    left.max(0L).min(2147483647L).to_int()
  })
  match (timeouts.attempt_ms, remaining) {
    (Some(attempt_ms), Some(remaining)) => Some(attempt_ms.min(remaining))
    (Some(limit), None) | (None, Some(limit)) => Some(limit)
    (None, None) => None
  }
}

///|
/// What to do after `error`: stop when the request's stream body was read
/// (`can_resend`), otherwise what the retry decider says.
fn Client::retry_decision(
  self : Client,
  error : SdkError,
  request : @http.Request,
  rebuilt : Bool,
  bucket : String,
  attempt : Int32,
  deadline : (Int64, Int32)?,
) -> Decision {
  guard can_resend(request, rebuilt~) else { return Stop(NotReplayable) }
  let now_unix_ms = self.clock.now_unix_ms()
  let context = RetryContext::new(
    request,
    bucket~,
    attempt~,
    random=(self.random)(),
    now_unix_ms~,
    remaining_ms?=deadline.map(deadline => deadline.0 - now_unix_ms),
    replayable=true,
  )
  self.retry.decide(error, context)
}

///|
/// One buffered attempt: admission, the exchange, the matching release, and
/// the observer, in that order.
async fn Client::send_once(
  self : Client,
  request : @http.Request,
  body : (() -> Bytes)?,
  bucket : String,
  global_exempt : Bool,
  attempt : Int32,
  deadline : (Int64, Int32)?,
) -> @http.Response raise SdkError {
  let response = self.admit_and_exchange(
    bucket,
    global_exempt,
    attempt,
    deadline,
    () => attempt_request(request, body),
    request => send_buffered(self.transport, self.middleware, request),
    response => (response.status, response.headers, response.body),
    _ => (),
  )
  classify(response, now_unix_ms=self.clock.now_unix_ms())
}

///|
/// One streaming attempt. The head is released and observed as soon as it
/// arrives, before the body is handed to the caller.
async fn Client::send_stream_once(
  self : Client,
  request : @http.Request,
  body : (() -> Bytes)?,
  bucket : String,
  global_exempt : Bool,
  attempt : Int32,
  deadline : (Int64, Int32)?,
) -> (@http.ResponseHead, &@http.BodyStream) raise SdkError {
  let (head, stream) = self.admit_and_exchange(
    bucket,
    global_exempt,
    attempt,
    deadline,
    () => attempt_request(request, body),
    request => send_streaming(self.transport, request),
    pair => (pair.0.status, pair.0.headers, b""),
    pair => pair.1.close(),
  )
  if head.status >= 200 && head.status <= 299 {
    return (head, stream)
  }
  let body = read_error_body(stream)
  let response : @http.Response = {
    status: head.status,
    headers: head.headers,
    body,
  }
  ignore(classify(response, now_unix_ms=self.clock.now_unix_ms()))
  raise Config("non-success streaming response was not classified")
}

///|
/// The request one attempt sends, as its own copy: with the deferred body
/// built now when there is one, and with the request's own body otherwise.
fn attempt_request(
  request : @http.Request,
  body : (() -> Bytes)?,
) -> @http.Request {
  match body {
    Some(build) => request.body_bytes(build())
    None => { ..request, headers: copy_headers(request.headers), }
  }
}

///|
/// Runs one exchange between the limiter's `acquire` and its `release`, and
/// reports it to the observer. `build` makes the attempt's request once the
/// limiter has admitted it, so nothing it allocates is held while waiting.
///
/// Every exit after `acquire` returns releases exactly once: a response
/// releases with its status, a transport failure releases with status `0`,
/// and a cancellation — which no `catch` sees but which does run `errdefer` —
/// releases with status `0` on the way out. A cancellation while waiting in
/// `acquire` releases nothing, because nothing was admitted.
///
/// `discard` frees a response that will not reach the caller, because the
/// release after it raised or was cancelled; a streaming response closes its
/// body there, since the caller never receives it to close.
///
/// With `Timeouts`, only the exchange is limited (`attempt_budget`, worked
/// out once the limiter has admitted the attempt): `acquire` and `release`
/// run unlimited so that they stay paired.
async fn[T] Client::admit_and_exchange(
  self : Client,
  bucket : String,
  global_exempt : Bool,
  attempt : Int32,
  deadline : (Int64, Int32)?,
  build : () -> @http.Request,
  exchange : async (@http.Request) -> T raise SdkError,
  head : (T) -> (Int32, @http.Headers, Bytes),
  discard : (T) -> Unit,
) -> T raise SdkError {
  self.limiter.acquire(bucket, global_exempt~) catch {
    error => raise Config("rate limiter acquire failed: \{error}")
  }
  let request = build()
  let started_at = self.clock.now_unix_ms()
  let budget = self.attempt_budget(deadline)
  let outcome = self.exchange_guarded(
    bucket, request, attempt, started_at, budget, exchange,
  )
  match outcome {
    Ok(value) => {
      let (status, headers, body) = head(value)
      // Observed after the release, whether or not the release itself raises.
      defer (self.observer)({
        bucket,
        request,
        attempt,
        status,
        headers,
        body,
        duration_ms: self.clock.now_unix_ms() - started_at,
        error: None,
      })
      errdefer discard(value)
      self.limiter.release(bucket, status~, headers~) catch {
        error => raise Config("rate limiter release failed: \{error}")
      }
      value
    }
    Err(error) => {
      self.settle_without_response(
        bucket,
        request,
        attempt,
        started_at,
        Some(error),
      )
      raise error
    }
  }
}

///|
/// The exchange itself, within `budget` milliseconds when there is one. A
/// transport failure, and running out of time, are captured as values, so
/// the only error that can leave this function is a cancellation, and the
/// `errdefer` settles the attempt for exactly that case.
#warnings("-result_error_return")
async fn[T] Client::exchange_guarded(
  self : Client,
  bucket : String,
  request : @http.Request,
  attempt : Int32,
  started_at : Int64,
  budget : Int32?,
  exchange : async (@http.Request) -> T raise SdkError,
) -> Result[T, SdkError] noraise {
  errdefer self.settle_without_response(
    bucket,
    request,
    attempt,
    started_at,
    None,
  )
  guard (self.timeouts, budget) is (Some(timeouts), Some(budget)) else {
    return Ok(exchange(request)) catch { error => Err(error) }
  }
  // A trait method cannot be generic, so the result leaves through a cell.
  // A result that is there is used even when the timer says time ran out:
  // the exchange did finish, and a stream it opened must not leak.
  let result : Ref[Result[T, SdkError]?] = Ref(None)
  let _ = timeouts.timer.within(budget, () => {
    result.val = Some(Ok(exchange(request)) catch { error => Err(error) })
  })
  match result.val {
    Some(result) => result
    None => Err(Transport(Timeout(phase=Unknown, ms=budget)))
  }
}

///|
/// Releases with status `0` and observes an attempt that got no response.
/// The observer is deferred so that it still runs when a release that suspends
/// is cut short by cancellation, which no `catch` sees.
async fn Client::settle_without_response(
  self : Client,
  bucket : String,
  request : @http.Request,
  attempt : Int32,
  started_at : Int64,
  error : SdkError?,
) -> Unit noraise {
  defer (self.observer)({
    bucket,
    request,
    attempt,
    status: 0,
    headers: @http.Headers::new(),
    body: b"",
    duration_ms: self.clock.now_unix_ms() - started_at,
    error,
  })
  self.limiter.release(bucket, status=0, headers=@http.Headers::new()) catch {
    _ => ()
  }
}

///|
async fn send_buffered(
  transport : &@http.Transport,
  middleware : Array[@http.Middleware],
  request : @http.Request,
) -> @http.Response raise SdkError {
  @http.send_with(transport, middleware, request) catch {
    error => raise Transport(error)
  }
}

///|
async fn send_streaming(
  transport : &@http.Transport,
  request : @http.Request,
) -> (@http.ResponseHead, &@http.BodyStream) raise SdkError {
  transport.send_stream(request) catch {
    error => raise Transport(error)
  }
}

///|
async fn read_error_body(stream : &@http.BodyStream) -> Bytes raise SdkError {
  defer stream.close()
  let bytes : Array[Byte] = []
  for ; bytes.length() < max_error_body_bytes; {
    let chunk = stream.read_some() catch { error => raise Transport(error) }
    guard chunk is Some(chunk) else { break }
    let take = chunk.length().min(max_error_body_bytes - bytes.length())
    for byte in chunk[:take] {
      bytes.push(byte)
    }
  }
  Bytes::from_array(bytes)
}

///|
fn Client::prepare(self : Client, request : @http.Request) -> @http.Request {
  let original_headers = request.headers
  let prepared = {
    ..request,
    headers: copy_headers(request.headers),
    url: resolve_url(self.base_url, request.url),
  }
  for pair in self.default_headers.iter() {
    if !original_headers.contains(pair.0) {
      prepared.headers.append(pair.0, pair.1)
    }
  }
  self.auth.apply(prepared)
}

///|
/// Joins a request path onto the base URL, or keeps an absolute `http(s)` URL
/// such as a pagination link. A join, not RFC 3986 resolution: `/chat` on
/// `https://api.openai.com/v1` must keep the base's `/v1`.
fn resolve_url(base_url : String, url : String) -> String {
  if absolute_http_url(url) {
    return url
  }
  if base_url.has_suffix("/") && url.has_prefix("/") {
    base_url + url[1:].to_owned()
  } else if base_url.has_suffix("/") || url.has_prefix("/") {
    base_url + url
  } else {
    base_url + "/" + url
  }
}

///|
/// Whether `url` is an absolute `http` or `https` URL with a host, in any
/// letter case.
fn absolute_http_url(url : String) -> Bool {
  if url.has_prefix("http://") || url.has_prefix("https://") {
    return true
  }
  try @http.Url::parse(url) catch {
    _ => false
  } noraise {
    parsed => parsed.scheme is Some("http" | "https") && parsed.host is Some(_)
  }
}

///|
fn copy_headers(headers : @http.Headers) -> @http.Headers {
  @http.Headers::from_array(headers.iter().to_array())
}
