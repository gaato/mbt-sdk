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
  attempt : Int
  status : Int
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
/// promptly.
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
    random: random.unwrap_or(default_random),
  }
}

///|
/// Sends a buffered request, retrying only as directed by the retry decider.
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
pub async fn Client::send(
  self : Client,
  request : @http.Request,
  bucket? : String,
  global_exempt? : Bool = false,
  body? : () -> Bytes,
) -> @http.Response raise SdkError {
  let request = self.prepare(request)
  let bucket = bucket.unwrap_or("")
  for attempt = 0; ; attempt = attempt + 1 {
    let outcome : Result[@http.Response, SdkError] = Ok(
      self.send_once(request, body, bucket, global_exempt, attempt),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(response) => return response
      Err(error) =>
        match
          self.retry.next_delay_ms(error, request, attempt, (self.random)()) {
          Some(delay) => self.clock.sleep(delay)
          None => raise error
        }
    }
  }
}

///|
/// Sends and decodes JSON; an empty successful body is JSON null. `body` is
/// as for `send`.
pub async fn Client::send_json(
  self : Client,
  request : @http.Request,
  bucket? : String,
  global_exempt? : Bool = false,
  body? : () -> Bytes,
) -> Json raise SdkError {
  let response = self.send(request, bucket?, global_exempt~, body?)
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
/// `body` is as for `send`.
pub async fn Client::send_stream(
  self : Client,
  request : @http.Request,
  bucket? : String,
  global_exempt? : Bool = false,
  body? : () -> Bytes,
) -> (@http.ResponseHead, &@http.BodyStream) raise SdkError {
  let request = self.prepare(request)
  let bucket = bucket.unwrap_or("")
  for attempt = 0; ; attempt = attempt + 1 {
    let outcome : Result[(@http.ResponseHead, &@http.BodyStream), SdkError] = Ok(
      self.send_stream_once(request, body, bucket, global_exempt, attempt),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(response) => return response
      Err(error) =>
        match
          self.retry.next_delay_ms(error, request, attempt, (self.random)()) {
          Some(delay) => self.clock.sleep(delay)
          None => raise error
        }
    }
  }
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
  attempt : Int,
) -> @http.Response raise SdkError {
  let response = self.admit_and_exchange(
    bucket,
    global_exempt,
    attempt,
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
  attempt : Int,
) -> (@http.ResponseHead, &@http.BodyStream) raise SdkError {
  let (head, stream) = self.admit_and_exchange(
    bucket,
    global_exempt,
    attempt,
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
    None => request.body_bytes(request.body)
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
async fn[T] Client::admit_and_exchange(
  self : Client,
  bucket : String,
  global_exempt : Bool,
  attempt : Int,
  build : () -> @http.Request,
  exchange : async (@http.Request) -> T raise SdkError,
  head : (T) -> (Int, @http.Headers, Bytes),
  discard : (T) -> Unit,
) -> T raise SdkError {
  self.limiter.acquire(bucket, global_exempt~) catch {
    error => raise Config("rate limiter acquire failed: \{error}")
  }
  let request = build()
  let started_at = self.clock.now_unix_ms()
  let outcome = self.exchange_guarded(
    bucket, request, attempt, started_at, exchange,
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
/// The exchange itself. A transport failure is captured as a value, so the
/// only error that can leave this function is a cancellation, and the
/// `errdefer` settles the attempt for exactly that case.
async fn[T] Client::exchange_guarded(
  self : Client,
  bucket : String,
  request : @http.Request,
  attempt : Int,
  started_at : Int64,
  exchange : async (@http.Request) -> T raise SdkError,
) -> Result[T, SdkError] noraise {
  errdefer self.settle_without_response(
    bucket,
    request,
    attempt,
    started_at,
    None,
  )
  Ok(exchange(request)) catch {
    error => Err(error)
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
  attempt : Int,
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
    @http.HttpError::Connect(message) =>
      raise Transport(@http.HttpError::Connect(message))
    @http.HttpError::Timeout(milliseconds) =>
      raise Transport(@http.HttpError::Timeout(milliseconds))
    @http.HttpError::Protocol(message) =>
      raise Transport(@http.HttpError::Protocol(message))
  }
}

///|
async fn send_streaming(
  transport : &@http.Transport,
  request : @http.Request,
) -> (@http.ResponseHead, &@http.BodyStream) raise SdkError {
  transport.send_stream(request) catch {
    @http.HttpError::Connect(message) =>
      raise Transport(@http.HttpError::Connect(message))
    @http.HttpError::Timeout(milliseconds) =>
      raise Transport(@http.HttpError::Timeout(milliseconds))
    @http.HttpError::Protocol(message) =>
      raise Transport(@http.HttpError::Protocol(message))
  }
}

///|
async fn read_error_body(stream : &@http.BodyStream) -> Bytes raise SdkError {
  defer stream.close()
  let bytes : Array[Byte] = []
  for ; bytes.length() < 1048576; {
    let chunk = stream.read_some() catch {
      @http.HttpError::Connect(message) =>
        raise Transport(@http.HttpError::Connect(message))
      @http.HttpError::Timeout(milliseconds) =>
        raise Transport(@http.HttpError::Timeout(milliseconds))
      @http.HttpError::Protocol(message) =>
        raise Transport(@http.HttpError::Protocol(message))
    }
    guard chunk is Some(chunk) else { break }
    let take = chunk.length().min(1048576 - bytes.length())
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
    ..request.body_bytes(request.body),
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
fn resolve_url(base_url : String, url : String) -> String {
  if url.has_prefix("http://") || url.has_prefix("https://") {
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
fn copy_headers(headers : @http.Headers) -> @http.Headers {
  @http.Headers::from_array(headers.iter().to_array())
}

///|
fn default_random() -> Double {
  match @env.rand(6) {
    Some(bytes) => {
      let mut value = 0L
      for byte in bytes {
        value = value * 256L + byte.to_int().to_int64()
      }
      value.to_double() / 281474976710656.0
    }
    None => 0.5
  }
}
