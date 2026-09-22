///|
/// A keep-alive connection parked between requests to one origin.
priv struct IdleConn {
  client : @ahttp.Client
  parked_at_ms : Int64
}

///|
/// Takes a young idle connection to `origin`, or dials a new one when there is
/// none or `fresh` is set. Idle connections that outlived `idle_max_ms` are
/// closed on the way. The flag says whether the connection was reused.
async fn AsyncTransport::checkout(
  self : AsyncTransport,
  origin : String,
  fresh~ : Bool,
) -> (@ahttp.Client, Bool) raise @http.HttpError {
  if self.closed {
    raise @http.HttpError::Connect("transport closed")
  }
  if !fresh && self.idle.get(origin) is Some(parked) {
    let now = @async.now()
    while parked.pop() is Some(conn) {
      if now - conn.parked_at_ms < self.idle_max_ms.to_int64() {
        return (conn.client, true)
      }
      conn.client.close()
    }
  }
  let client = @ahttp.Client(origin) catch {
    @ahttp.URIParseError::InvalidFormat =>
      raise @http.HttpError::Protocol("invalid URL")
    @ahttp.URIParseError::UnsupportedProtocol(protocol) =>
      raise @http.HttpError::Protocol("unsupported protocol: " + protocol)
    error => raise @http.HttpError::Connect(error.to_string())
  }
  (client, false)
}

///|
/// Parks a connection whose response body has been fully consumed, or closes
/// it when the transport is closed or the origin already holds enough.
fn AsyncTransport::checkin(
  self : AsyncTransport,
  origin : String,
  client : @ahttp.Client,
) -> Unit {
  if self.closed || self.max_idle_per_origin <= 0 || self.idle_max_ms <= 0 {
    client.close()
    return
  }
  let parked = self.idle.get_or_init(origin, () => [])
  if parked.length() >= self.max_idle_per_origin {
    client.close()
    return
  }
  parked.push({ client, parked_at_ms: @async.now(), })
}

///|
/// Closes every idle connection and refuses further requests with
/// `Connect("transport closed")`. In-flight requests finish and their
/// connections are closed instead of parked.
///
/// ```mbt check
/// test {
///   let transport = @adapter.AsyncTransport::new()
///   transport.close()
///   assert_eq(transport.idle_connections(), 0)
/// }
/// ```
pub fn AsyncTransport::close(self : AsyncTransport) -> Unit {
  self.closed = true
  for _, parked in self.idle {
    for conn in parked {
      conn.client.close()
    }
  }
  self.idle.clear()
}

///|
/// The number of parked keep-alive connections across all origins.
pub fn AsyncTransport::idle_connections(self : AsyncTransport) -> Int {
  let mut total = 0
  for _, parked in self.idle {
    total += parked.length()
  }
  total
}

///|
/// Whether a request may be sent again on a fresh connection after a reused
/// one failed before producing a response head: idempotent methods, or any
/// request carrying an `Idempotency-Key`.
fn replayable(request : @http.Request) -> Bool {
  if request.headers.contains("idempotency-key") {
    return true
  }
  match request.http_method.to_lower() {
    "get" | "head" | "put" | "delete" | "options" | "trace" => true
    _ => false
  }
}

///|
/// Whether the server asked to close the connection after this response.
fn connection_close(response : @ahttp.Response) -> Bool {
  for name, value in response.headers {
    if name.0.to_lower() == "connection" && value.to_lower().contains("close") {
      return true
    }
  }
  false
}
