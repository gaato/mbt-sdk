///|
/// A transport-independent SDK client with authentication, retry, and limits.
pub struct Client {
  priv transport : &@http.Transport
  priv clock : &@clock.Clock
  priv base_url : String
  priv default_headers : @http.Headers
  priv auth : Auth
  priv retry : RetryPolicy
  priv limiter : &RateLimiter
  priv middleware : Array[@http.Middleware]
  priv random : () -> Double
}

///|
/// Creates a client from injected transport and clock implementations.
pub fn Client::new(
  transport : &@http.Transport,
  clock : &@clock.Clock,
  base_url~ : String,
  default_headers? : @http.Headers,
  auth? : Auth,
  retry? : RetryPolicy,
  limiter? : &RateLimiter,
  middleware? : Array[@http.Middleware],
  random? : () -> Double,
) -> Client {
  let default_headers = default_headers
    .map(copy_headers)
    .unwrap_or_else(@http.Headers::new)
  let no_limiter : &RateLimiter = NoLimiter::new()
  {
    transport,
    clock,
    base_url,
    default_headers,
    auth: auth.unwrap_or(NoAuth),
    retry: retry.unwrap_or_else(RetryPolicy::default),
    limiter: limiter.unwrap_or(no_limiter),
    middleware: middleware.map(Array::copy).unwrap_or([]),
    random: random.unwrap_or(default_random),
  }
}

///|
/// Sends a buffered request, retrying only as directed by `RetryPolicy`.
pub async fn Client::send(
  self : Client,
  request : @http.Request,
  bucket? : String,
) -> @http.Response raise SdkError {
  let request = self.prepare(request)
  let bucket = bucket.unwrap_or("")
  for attempt = 0; ; attempt = attempt + 1 {
    let outcome : Result[@http.Response, SdkError] = Ok(
      self.send_once(request, bucket),
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
/// Sends and decodes JSON; an empty successful body is JSON null.
pub async fn Client::send_json(
  self : Client,
  request : @http.Request,
  bucket? : String,
) -> Json raise SdkError {
  let response = self.send(request, bucket?)
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
pub async fn Client::send_stream(
  self : Client,
  request : @http.Request,
  bucket? : String,
) -> (@http.ResponseHead, &@http.BodyStream) raise SdkError {
  let request = self.prepare(request)
  let bucket = bucket.unwrap_or("")
  for attempt = 0; ; attempt = attempt + 1 {
    let outcome : Result[(@http.ResponseHead, &@http.BodyStream), SdkError] = Ok(
      self.send_stream_once(request, bucket),
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
async fn Client::send_once(
  self : Client,
  request : @http.Request,
  bucket : String,
) -> @http.Response raise SdkError {
  self.limiter.acquire(bucket)
  let response = send_buffered(
    self.transport,
    self.middleware,
    request.body_bytes(request.body),
  )
  let now = self.clock.now_unix_ms()
  self.limiter.observe(bucket, response.status, response.headers, now)
  classify(response, now_unix_ms=now)
}

///|
async fn Client::send_stream_once(
  self : Client,
  request : @http.Request,
  bucket : String,
) -> (@http.ResponseHead, &@http.BodyStream) raise SdkError {
  self.limiter.acquire(bucket)
  let (head, stream) = send_streaming(
    self.transport,
    request.body_bytes(request.body),
  )
  let now = self.clock.now_unix_ms()
  self.limiter.observe(bucket, head.status, head.headers, now)
  if head.status >= 200 && head.status <= 299 {
    return (head, stream)
  }
  let body = read_error_body(stream)
  let response : @http.Response = {
    status: head.status,
    headers: head.headers,
    body,
  }
  ignore(classify(response, now_unix_ms=now))
  raise Config("non-success streaming response was not classified")
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
