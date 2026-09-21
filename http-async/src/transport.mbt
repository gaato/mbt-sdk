///|
/// An HTTP transport with one client per request and bounded IO operations.
pub struct AsyncTransport {
  priv timeout_ms : Int
}

///|
/// Creates a transport. Streaming reads each receive a fresh idle timeout.
///
/// ```mbt check
/// test {
///   let _ = @adapter.AsyncTransport::new(timeout_ms=1000)
/// }
/// ```
pub fn AsyncTransport::new(timeout_ms? : Int = 30000) -> AsyncTransport {
  { timeout_ms, }
}

///|
/// Explicit transport methods for buffered and streaming requests.
pub extend AsyncTransport with @http.Transport::{send, send_stream}

///|
/// Reads the entire response within one timeout, regardless of status.
pub impl @http.Transport for AsyncTransport with fn send(self, request) {
  bounded(self.timeout_ms, () => {
    let (head, client) = open_request(request)
    defer client.close()
    let body = client.read_all().binary() catch {
        error => raise @http.HttpError::Protocol(error.to_string())
      }
    @http.Response::{ status: head.status, headers: head.headers, body, }
  })
}

///|
/// Reads the response head within one timeout and transfers ownership to a stream.
pub impl @http.Transport for AsyncTransport with fn send_stream(self, request) {
  // Retain ownership until the timeout scope has actually returned to the caller.
  let mut opened : @ahttp.Client? = None
  errdefer (if opened is Some(client) { client.close() })
  bounded(self.timeout_ms, () => {
    let (head, client) = open_request(request)
    opened = Some(client)
    let stream : &@http.BodyStream = ClientStream::{
      client,
      timeout_ms: self.timeout_ms,
      closed: false,
    }
    (head, stream)
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
  client : @ahttp.Client
  timeout_ms : Int
  mut closed : Bool
}

///|
impl @http.BodyStream for ClientStream with fn close(self) {
  if !self.closed {
    self.closed = true
    self.client.close()
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
    @http.BodyStream::close(self)
  }
  chunk
}

///|
async fn open_request(
  request : @http.Request,
) -> (@http.ResponseHead, @ahttp.Client) raise @http.HttpError {
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
  let client = @ahttp.Client(origin, headers~) catch {
    @ahttp.URIParseError::InvalidFormat =>
      raise @http.HttpError::Protocol("invalid URL")
    @ahttp.URIParseError::UnsupportedProtocol(protocol) =>
      raise @http.HttpError::Protocol("unsupported protocol: " + protocol)
    error => raise @http.HttpError::Connect(error.to_string())
  }
  errdefer client.close()
  let response = try {
    client.request(meth, path)
    client.write(request.body)
    client.end_request()
  } catch {
    error => raise head_error(error)
  }
  (response_head(response), client)
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
