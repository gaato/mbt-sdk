///|
/// An HTTP transport with bounded IO operations and a small keep-alive pool.
///
/// A connection returns to the pool only after its response body has been
/// consumed in full and the server did not answer `Connection: close`. At most
/// `max_idle_per_origin` connections are parked per origin, each for at most
/// `idle_max_ms`; concurrent requests beyond that dial new connections and are
/// never queued. When a reused connection fails before a response head, the
/// request is sent once more on a fresh connection if it is idempotent or
/// carries an `Idempotency-Key`; other requests surface the failure.
pub struct AsyncTransport {
  priv timeout_ms : Int
  priv max_idle_per_origin : Int
  priv idle_max_ms : Int
  priv idle : Map[String, Array[IdleConn]]
  priv mut closed : Bool
}

///|
/// Creates a transport. Streaming reads each receive a fresh idle timeout.
/// `max_idle_per_origin = 0` or `idle_max_ms = 0` disables connection reuse.
///
/// ```mbt check
/// test {
///   let _ = @adapter.AsyncTransport::new(timeout_ms=1000)
///   let _ = @adapter.AsyncTransport::new(max_idle_per_origin=0)
/// }
/// ```
pub fn AsyncTransport::new(
  timeout_ms? : Int = 30000,
  max_idle_per_origin? : Int = 4,
  idle_max_ms? : Int = 10000,
) -> AsyncTransport {
  { timeout_ms, max_idle_per_origin, idle_max_ms, idle: {}, closed: false, }
}

///|
/// Explicit transport methods for buffered and streaming requests.
pub extend AsyncTransport with @http.Transport::{send, send_stream}

///|
/// Reads the entire response within one timeout, regardless of status.
pub impl @http.Transport for AsyncTransport with fn send(self, request) {
  bounded(self.timeout_ms, () => {
    let opened = self.open_request(request)
    errdefer opened.client.close()
    let body = opened.client.read_all().binary() catch {
        error => raise @http.HttpError::Protocol(error.to_string())
      }
    self.release(opened)
    @http.Response::{
      status: opened.head.status,
      headers: opened.head.headers,
      body,
    }
  })
}

///|
/// Reads the response head within one timeout and transfers ownership to a stream.
pub impl @http.Transport for AsyncTransport with fn send_stream(self, request) {
  // Retain ownership until the timeout scope has actually returned to the caller.
  let mut opened : @ahttp.Client? = None
  errdefer (if opened is Some(client) { client.close() })
  bounded(self.timeout_ms, () => {
    let exchange = self.open_request(request)
    opened = Some(exchange.client)
    let stream : &@http.BodyStream = ClientStream::{
      transport: self,
      origin: exchange.origin,
      client: exchange.client,
      keep_alive: exchange.keep_alive,
      timeout_ms: self.timeout_ms,
      finished: false,
      closed: false,
    }
    (exchange.head, stream)
  })
}

///|
/// Runs `f` under one deadline. Expiry surfaces as `Timeout(ms)`; every other
/// failure is narrowed to `HttpError`. Cancellation is not an `Error` in
/// moonbitlang/async, so `catch` never sees it and it propagates untouched.
async fn[X] bounded(
  ms : Int,
  f : async () -> X raise @http.HttpError,
) -> X raise @http.HttpError {
  if ms <= 0 {
    raise @http.HttpError::Timeout(ms)
  }
  @async.with_timeout(ms, () => f(), error=@http.HttpError::Timeout(ms)) catch {
    @http.HttpError::Connect(message) => raise @http.HttpError::Connect(message)
    @http.HttpError::Protocol(message) =>
      raise @http.HttpError::Protocol(message)
    @http.HttpError::Timeout(timeout) => raise @http.HttpError::Timeout(timeout)
    other => raise @http.HttpError::Protocol(other.to_string())
  }
}

///|
priv struct ClientStream {
  transport : AsyncTransport
  origin : String
  client : @ahttp.Client
  keep_alive : Bool
  timeout_ms : Int
  mut finished : Bool
  mut closed : Bool
}

///|
/// Parks the connection when the body was read to its end; closes it when
/// the stream is abandoned early.
impl @http.BodyStream for ClientStream with fn close(self) {
  if !self.closed {
    self.closed = true
    if self.finished && self.keep_alive {
      self.transport.checkin(self.origin, self.client)
    } else {
      self.client.close()
    }
  }
}

///|
impl @http.BodyStream for ClientStream with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @http.BodyStream::close(self)
  let chunk = bounded(self.timeout_ms, () => {
    self.client.read_some() catch {
      error => raise @http.HttpError::Protocol(error.to_string())
    }
  })
  if chunk is None {
    self.finished = true
    @http.BodyStream::close(self)
  }
  chunk
}

///|
/// One exchange whose response head has arrived; the body is still on `client`.
priv struct Opened {
  head : @http.ResponseHead
  client : @ahttp.Client
  origin : String
  keep_alive : Bool
}

///|
/// Parks or closes the connection of a fully consumed exchange.
fn AsyncTransport::release(self : AsyncTransport, opened : Opened) -> Unit {
  if opened.keep_alive {
    self.checkin(opened.origin, opened.client)
  } else {
    opened.client.close()
  }
}

///|
async fn AsyncTransport::open_request(
  self : AsyncTransport,
  request : @http.Request,
) -> Opened raise @http.HttpError {
  let meth = request_method(request.http_method)
  let (origin, path) = split_url(request.url)
  let headers : @ahttp.Headers = Map([])
  for (name, value) in request.headers.iter() {
    if name == "content-length" {
      continue
    }
    let key = @ahttp.CaseInsensitiveString(name)
    headers[key] = match headers.get(key) {
      None => value
      Some(previous) => previous + ", " + value
    }
  }
  let mut fresh = false
  for ;; {
    let (client, reused) = self.checkout(origin, fresh~)
    let response = exchange(client, meth, path, headers, request.body) catch {
      error => {
        if reused && replayable(request) {
          // A parked connection the server had already dropped: replay once
          // on a fresh one. `reused` is false on that second attempt.
          fresh = true
          continue
        }
        raise head_error(error)
      }
    }
    return {
      head: response_head(response),
      client,
      origin,
      keep_alive: !connection_close(response),
    }
  }
}

///|
/// Writes one request and reads its response head. The connection is closed
/// on any failure, including cancellation, which bypasses `catch`.
async fn exchange(
  client : @ahttp.Client,
  meth : @ahttp.RequestMethod,
  path : String,
  headers : @ahttp.Headers,
  body : Bytes,
) -> @ahttp.Response {
  errdefer client.close()
  client.request(meth, path, extra_headers=headers)
  client.write(body)
  client.end_request()
}

///|
fn request_method(meth : String) -> @ahttp.RequestMethod raise @http.HttpError {
  match meth.to_lower() {
    "get" => Get
    "head" => Head
    "post" => Post
    "put" => Put
    "delete" => Delete
    "connect" => Connect
    "options" => Options
    "trace" => Trace
    "patch" => Patch
    _ => raise @http.HttpError::Protocol("unknown HTTP method: " + meth)
  }
}

///|
fn split_url(url : String) -> (String, String) raise @http.HttpError {
  guard url.find("://") is Some(scheme_end) else {
    raise @http.HttpError::Protocol("expected an absolute HTTP URL")
  }
  let scheme = url[:scheme_end].to_owned().to_lower()
  guard scheme == "http" || scheme == "https" else {
    raise @http.HttpError::Protocol("unsupported URL scheme: " + scheme)
  }
  let rest = url[scheme_end + 3:]
  let end = rest.find("#").unwrap_or(rest.length())
  let rest = rest[:end]
  let authority_end = rest
    .find("/")
    .unwrap_or(rest.length())
    .min(rest.find("?").unwrap_or(rest.length()))
  let authority = rest[:authority_end]
  guard !authority.is_empty() else {
    raise @http.HttpError::Protocol("empty URL authority")
  }
  let tail = rest[authority_end:]
  let path = if tail.has_prefix("/") {
    tail.to_owned()
  } else {
    "/" + tail.to_owned()
  }
  (scheme + "://" + authority.to_owned(), path)
}

///|
fn response_head(response : @ahttp.Response) -> @http.ResponseHead {
  let headers = @http.Headers::new()
  for name, value in response.headers {
    headers.append(name.0, value)
  }
  // async exposes Set-Cookie separately; preserve each parsed cookie as a value.
  for cookie in response.cookies {
    let text = StringBuilder()
    text.write_string(cookie.name + "=" + cookie.value)
    if cookie.path is Some(value) {
      text.write_string("; Path=" + value)
    }
    if cookie.expires_raw is Some(value) {
      text.write_string("; Expires=" + value)
    }
    if cookie.max_age is Some(value) {
      text.write_string("; Max-Age=" + value.to_string())
    }
    if cookie.domain is Some(value) {
      text.write_string("; Domain=" + value)
    }
    if cookie.secure {
      text.write_string("; Secure")
    }
    if cookie.http_only {
      text.write_string("; HttpOnly")
    }
    for extension in cookie.extensions {
      text.write_string("; " + extension)
    }
    headers.append("set-cookie", text.to_string())
  }
  { status: response.code, headers, }
}
