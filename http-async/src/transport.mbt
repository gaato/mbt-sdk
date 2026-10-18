///|
/// An HTTP transport with bounded IO operations and a small keep-alive pool.
///
/// A connection returns to the pool only after its response body has been
/// consumed in full and the server did not answer `Connection: close`. At most
/// `max_idle_per_origin` connections are parked per origin, each reusable for
/// at most `idle_max_ms`; concurrent requests beyond that dial new connections.
/// They queue only under `max_connections` or `max_connections_per_origin`,
/// which cap the connections in use (parked ones do not count). No timer
/// runs: every request, to any origin, closes the parked connections that
/// have expired, so a transport left unused holds them until its next request
/// or `close()`. When a reused connection fails
/// before a response head, the request is sent once more on a fresh connection
/// if it is idempotent or carries an `Idempotency-Key` and its body is not a
/// stream already read; other requests surface the failure.
///
/// A body in memory is sent with `Content-Length`; so is a stream body
/// declared with a length (`Request::body_stream`), while one without is sent
/// `Transfer-Encoding: chunked`. A body is written in slices of at most
/// 64 KiB, each as it is read from a stream, which is taken once and closed
/// when the request is sent or fails. On JS, moonbitlang/async hands fetch
/// the body whole, so a stream body is read into memory first and one over
/// 16 MiB fails with `Protocol` before anything is sent; send larger bodies
/// as bytes there.
///
/// On native and Wasm, a request without `Accept-Encoding` is sent with
/// `Accept-Encoding: gzip, deflate, br` and its response body is decoded: the
/// codings undone leave `Content-Encoding`, `Content-Length` is dropped, and an
/// unknown coding stays on the body untouched. A request that sets
/// `Accept-Encoding` itself gets the body as sent. On JS, fetch does both.
pub struct AsyncTransport {
  priv limits : Timeouts
  priv clock : &@clock.Clock
  priv max_body_bytes : Int32?
  priv pool : IdlePool[@ahttp.Client]
  priv slots : Slots
}

///|
/// Creates a transport.
///
/// Time limits, in milliseconds; a nonpositive one fails at once:
/// - `timeout_ms` bounds an exchange from the call, slot wait included: a
///   buffered one to the end of its body, a streaming one to its head. Every
///   phase ends at that deadline at the latest, reporting `ms=timeout_ms`.
/// - `connect_timeout_ms` bounds dialing a new connection: DNS, TCP and TLS.
/// - `write_timeout_ms` bounds sending the request head, and each write of
///   at most 64 KiB of the body on its own; for a stream body, each read from
///   the stream as well.
/// - `read_timeout_ms` bounds waiting for the head, and each body read on its
///   own. It alone bounds a stream's reads.
/// - `pool_timeout_ms` bounds the wait for a slot under a connection cap.
///
/// Each phase limit defaults to `timeout_ms`, which keeps one limit for the
/// exchange and one per stream read. A timeout names its phase: `Pool`,
/// `Dial`, `Write`, `Head` or `Body`. On JS, fetch connects, sends and waits
/// for the head in one call, under `read_timeout_ms` and as phase `Unknown`;
/// the connect and write limits do not apply there.
///
/// `max_connections` caps the connections in use across origins, and
/// `max_connections_per_origin` those to one origin: a connection is in use
/// from its request's slot until its body is read or abandoned. A request
/// over a cap waits for a slot, first come first served among the waiters a
/// freed slot fits, until `pool_timeout_ms`; caps below 1 count as 1. Unset,
/// requests never wait.
///
/// `max_idle_per_origin = 0` or `idle_max_ms = 0` disables connection reuse.
/// `max_body_bytes` bounds a buffered response body, counted after decoding:
/// a longer one closes the connection and fails with `Protocol`. Without it
/// the body is unbounded. Streams are never bounded, since their reader
/// decides what to keep.
///
/// ```mbt check
/// test {
///   let _ = @adapter.AsyncTransport::new(timeout_ms=1000)
///   let _ = @adapter.AsyncTransport::new(
///     connect_timeout_ms=5000,
///     read_timeout_ms=60000,
///   )
///   let _ = @adapter.AsyncTransport::new(max_connections_per_origin=8)
///   let _ = @adapter.AsyncTransport::new(max_idle_per_origin=0)
///   let _ = @adapter.AsyncTransport::new(max_body_bytes=1_048_576)
/// }
/// ```
pub fn AsyncTransport::new(
  timeout_ms~ : Int32 = 30000,
  connect_timeout_ms? : Int32,
  write_timeout_ms? : Int32,
  read_timeout_ms? : Int32,
  pool_timeout_ms? : Int32,
  max_connections? : Int32,
  max_connections_per_origin? : Int32,
  max_idle_per_origin~ : Int32 = 4,
  idle_max_ms~ : Int32 = 10000,
  max_body_bytes? : Int32,
) -> AsyncTransport {
  {
    limits: {
      total: timeout_ms,
      pool: pool_timeout_ms.unwrap_or(timeout_ms),
      connect: connect_timeout_ms.unwrap_or(timeout_ms),
      write: write_timeout_ms.unwrap_or(timeout_ms),
      read: read_timeout_ms.unwrap_or(timeout_ms),
    },
    clock: AsyncClock::new(),
    max_body_bytes,
    pool: IdlePool::new(max_per_origin=max_idle_per_origin, idle_max_ms~),
    slots: Slots::new(
      max_total?=max_connections,
      max_per_origin?=max_connections_per_origin,
    ),
  }
}

///|
/// Explicit transport methods for buffered and streaming requests.
pub extend AsyncTransport with @http.Transport::{send, send_stream}

///|
/// Reads the entire response within the exchange timeout, regardless of status.
pub impl @http.Transport for AsyncTransport with fn send(self, request) {
  let timer = PhaseTimer::exchange(self.clock, self.limits)
  let opened = self.open_request(request, timer)
  errdefer self.discard(opened.origin, opened.client)
  let body = read_body(
    opened.client,
    opened.decoder,
    self.max_body_bytes,
    timer,
  )
  self.release(opened)
  @http.Response::{
    status: opened.head.status,
    headers: opened.head.headers,
    body,
  }
}

///|
/// Reads the response head within the exchange timeout and transfers
/// ownership of the connection to a stream.
pub impl @http.Transport for AsyncTransport with fn send_stream(self, request) {
  let exchange = self.open_request(
    request,
    PhaseTimer::exchange(self.clock, self.limits),
  )
  let stream : &@http.BodyStream = ClientStream::{
    transport: self,
    origin: exchange.origin,
    user_agent: exchange.user_agent,
    client: exchange.client,
    decoder: exchange.decoder,
    keep_alive: exchange.keep_alive,
    timer: PhaseTimer::stream(self.clock, self.limits),
    finished: false,
    closed: false,
  }
  (exchange.head, stream)
}

///|
/// The most bytes one read takes from a connection. Without `max_len`, a read
/// returns whatever the connection has buffered, so a stream's chunk, and the
/// overshoot past `max_body_bytes` before it is refused, would be bounded only
/// by that buffer. A decoded read is cut to the same size.
let max_read_bytes : Int32 = 64 * 1024

///|
/// The next chunk of a body: the next `read`, or with a `decoder`, the next
/// decoded slice, reading only as much as that slice needs.
async fn read_decoded(
  read : async () -> Bytes?,
  decoder : ContentDecoder?,
) -> Bytes? {
  guard decoder is Some(decoder) else { return read() }
  for ;; {
    match decoder.pull() {
      Slice(slice) => return Some(slice)
      Done => return None
      NeedInput =>
        match read() {
          Some(chunk) => decoder.feed(chunk)
          None => decoder.end()
        }
    }
  }
}

///|
/// The next chunk of a response body as one `Body` phase of `timer`.
async fn read_chunk(
  client : @ahttp.Client,
  decoder : ContentDecoder?,
  timer : PhaseTimer,
) -> Bytes? raise @http.HttpError {
  timer.run(Body, () => {
    read_decoded(() => client.read_some(max_len=max_read_bytes), decoder)
  })
}

///|
/// The rest of a response body, decoded, refused once it exceeds `max_bytes`.
async fn read_body(
  client : @ahttp.Client,
  decoder : ContentDecoder?,
  max_bytes : Int32?,
  timer : PhaseTimer,
) -> Bytes raise @http.HttpError {
  read_bounded(
    () => read_chunk(client, decoder, timer),
    max_bytes.unwrap_or(2147483647), // no limit short of `Int32`
  ) catch {
    error => raise failure(Body, error)
  }
}

///|
/// Chunks from `read` until it returns `None`. The chunk that would take the
/// total past `max_bytes` raises `Protocol` without reading further.
async fn read_bounded(read : async () -> Bytes?, max_bytes : Int32) -> Bytes {
  let body = Buffer()
  while read() is Some(chunk) {
    if chunk.length() > max_bytes - body.length() {
      raise @http.HttpError::Protocol(
        "response body larger than \{max_bytes} bytes",
      )
    }
    body.write_bytes(chunk)
  }
  body.to_bytes()
}

///|
priv struct ClientStream {
  transport : AsyncTransport
  origin : String
  user_agent : String?
  client : @ahttp.Client
  decoder : ContentDecoder?
  keep_alive : Bool
  timer : PhaseTimer
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
      self.transport.checkin(self.origin, self.user_agent, self.client)
      self.transport.slots.release(self.origin)
    } else {
      self.transport.discard(self.origin, self.client)
    }
  }
}

///|
impl @http.BodyStream for ClientStream with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @http.BodyStream::close(self)
  let chunk = read_chunk(self.client, self.decoder, self.timer)
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
  decoder : ContentDecoder?
  origin : String
  user_agent : String?
  keep_alive : Bool
}

///|
/// Parks or closes the connection of a fully consumed exchange and frees its
/// slot.
fn AsyncTransport::release(self : AsyncTransport, opened : Opened) -> Unit {
  if opened.keep_alive {
    self.checkin(opened.origin, opened.user_agent, opened.client)
    self.slots.release(opened.origin)
  } else {
    self.discard(opened.origin, opened.client)
  }
}

///|
/// Closes the connection of an exchange that ends early and frees its slot.
fn AsyncTransport::discard(
  self : AsyncTransport,
  origin : String,
  client : @ahttp.Client,
) -> Unit {
  client.close()
  self.slots.release(origin)
}

///|
/// The request headers as sent, with `User-Agent` pulled out because
/// connections are dialed and reused per user agent. `Content-Length` and
/// `Transfer-Encoding` are dropped since the transport frames the body
/// itself; repeated names are comma-joined.
fn wire_headers(headers : @http.Headers) -> (@ahttp.Headers, String?) {
  let wire : @ahttp.Headers = Map([])
  let mut user_agent : String? = None
  for (name, value) in headers.iter() {
    if name == "content-length" || name == "transfer-encoding" {
      continue
    }
    if name == "user-agent" {
      user_agent = Some(
        match user_agent {
          None => value
          Some(previous) => previous + ", " + value
        },
      )
      continue
    }
    let key = @ahttp.CaseInsensitiveString(name)
    wire[key] = match wire.get(key) {
      None => value
      Some(previous) => previous + ", " + value
    }
  }
  (wire, user_agent)
}

///|
/// Takes a connection slot, sends `request` and reads its response head, each
/// phase under `timer`. The slot passes to the returned exchange.
async fn AsyncTransport::open_request(
  self : AsyncTransport,
  request : @http.Request,
  timer : PhaseTimer,
) -> Opened raise @http.HttpError {
  let meth = request_method(request.http_method)
  let (origin, path) = split_url(request.url)
  let (headers, user_agent) = wire_headers(request.headers)
  let negotiated = negotiates_content_coding &&
    !request.headers.contains("accept-encoding")
  if negotiated {
    headers[@ahttp.CaseInsensitiveString("Accept-Encoding")] = accept_encoding()
  }
  if declares_content_length &&
    content_length(request.http_method, request.body) is Some(length) {
    headers[@ahttp.CaseInsensitiveString("Content-Length")] = length.to_string()
  }
  refuse_unbufferable(request.body, buffered_stream_limit)
  if self.pool.closed {
    raise @http.HttpError::Connect("transport closed")
  }
  self.slots.acquire(origin, timer)
  errdefer self.slots.release(origin)
  let mut fresh = false
  for ;; {
    let (client, reused) = self.checkout(origin, user_agent, fresh~, timer)
    let response = exchange(client, meth, path, headers, request.body, timer) catch {
      @http.HttpError::Network(..) if reused && replayable(request) => {
        // A parked connection the server had already dropped: replay once
        // on a fresh one. `reused` is false on that second attempt.
        fresh = true
        continue
      }
      error => raise error
    }
    let head = response_head(response)
    let decoder = if negotiated && has_body(request.http_method, head.status) {
      errdefer client.close()
      decode_head(head)
    } else {
      None
    }
    return {
      head,
      client,
      decoder,
      origin,
      user_agent,
      keep_alive: !connection_close(response),
    }
  }
}

///|
/// Writes one request as `Write` phases of `timer` (the head, then the body
/// slice by slice, see `send_body`) and reads its response head as the `Head`
/// phase. Each slice is flushed within its phase, the head with the first
/// slice or alone when there is no body; the few bytes that end a
/// chunked body go out with the head's phase. The connection is closed on any
/// failure, including cancellation, which bypasses `catch`.
async fn exchange(
  client : @ahttp.Client,
  meth : @ahttp.RequestMethod,
  path : String,
  headers : @ahttp.Headers,
  body : @http.Body,
  timer : PhaseTimer,
) -> @ahttp.Response raise @http.HttpError {
  errdefer client.close()
  // A stream is taken before the head goes out, so one that was already sent
  // fails without a byte of this request reaching the server.
  let outgoing = open_body(body)
  defer outgoing.close()
  let empty = body.length() is Some(0L)
  if empty {
    // A head declaring no body goes out whole before any body is read, so an
    // empty stream proves it is empty first, and is not read again.
    confirm_empty(outgoing, timer)
  }
  timer.run(Write, () => {
    client.request(meth, path, extra_headers=headers)
    // With a body, the head goes out with its first slice.
    if empty {
      client.flush()
    }
  })
  if !empty {
    send_outgoing(
      outgoing,
      slice => {
        client.write(slice)
        client.flush()
      },
      timer,
      buffer_limit=buffered_stream_limit,
    )
    // A stream of unknown length that ended at once wrote no slice, so its
    // head is still unsent: it goes out in the Write phase, not the Head one.
    timer.run(Write, () => client.flush())
  }
  timer.run(Head, () => client.end_request())
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
  (canonical_origin(scheme, authority.to_owned()), path)
}

///|
/// The origin of `scheme://authority` in one spelling per server, so the idle
/// pool and the connection caps key every spelling alike: lower-case scheme
/// and host, canonical IPv6, no default port. Userinfo is dropped: it is not
/// part of an origin, and the transport never sends it.
fn canonical_origin(
  scheme : String,
  authority : String,
) -> String raise @http.HttpError {
  let url = @http.Url::parse(scheme + "://" + authority + "/") catch {
    @http.UrlError::Invalid(reason) =>
      raise @http.HttpError::Protocol("invalid URL authority: " + reason)
  }
  let builder = StringBuilder()
  builder.write_string(scheme)
  builder.write_string("://")
  let host = url.host.unwrap_or("")
  if host.contains(":") {
    // An IPv6 literal: `Url` keeps the host without its brackets.
    builder.write_char('[')
    builder.write_string(host)
    builder.write_char(']')
  } else {
    builder.write_string(host)
  }
  if url.port is Some(port) {
    builder.write_char(':')
    builder.write_string(port.to_string())
  }
  builder.to_string()
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
