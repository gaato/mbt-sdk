///|
/// A keep-alive connection parked between requests to one origin.
priv struct IdleConn[C] {
  conn : C
  user_agent : String?
  parked_at_ms : Int64
}

///|
/// Parked keep-alive connections per origin. Generic over the connection so
/// the bookkeeping runs without sockets in tests; methods hand back the
/// connections the caller must close.
priv struct IdlePool[C] {
  max_per_origin : Int32
  idle_max_ms : Int32
  parked : Map[String, Array[IdleConn[C]]]
  mut closed : Bool
}

///|
fn[C] IdlePool::new(
  max_per_origin~ : Int32,
  idle_max_ms~ : Int32,
) -> IdlePool[C] {
  { max_per_origin, idle_max_ms, parked: {}, closed: false, }
}

///|
/// Takes out every connection that outlived `idle_max_ms`, across all origins,
/// and forgets origins left without connections. The pool holds at most
/// `max_per_origin` connections per origin, so a full pass stays cheap.
fn[C] IdlePool::sweep(self : IdlePool[C], now~ : Int64) -> Array[C] {
  let expired = []
  let emptied = []
  for origin, parked in self.parked {
    for i = parked.length() - 1; i >= 0; i = i - 1 {
      if now - parked[i].parked_at_ms >= self.idle_max_ms.to_int64() {
        expired.push(parked.remove(i).conn)
      }
    }
    if parked.is_empty() {
      emptied.push(origin)
    }
  }
  for origin in emptied {
    self.parked.remove(origin)
  }
  expired
}

///|
/// Takes the newest connection to `origin` parked with `user_agent`. Expired
/// connections of every origin are handed back alongside.
fn[C] IdlePool::take(
  self : IdlePool[C],
  origin : String,
  user_agent : String?,
  now~ : Int64,
) -> (C?, Array[C]) {
  let expired = self.sweep(now~)
  guard self.parked.get(origin) is Some(parked) else { return (None, expired) }
  for i = parked.length() - 1; i >= 0; i = i - 1 {
    if parked[i].user_agent == user_agent {
      let idle = parked.remove(i)
      if parked.is_empty() {
        self.parked.remove(origin)
      }
      return (Some(idle.conn), expired)
    }
  }
  (None, expired)
}

///|
/// Parks `conn`, or hands it back when the pool is closed, reuse is disabled,
/// or `origin` already holds `max_per_origin` young connections. Expired
/// connections of every origin are handed back alongside, before the cap is
/// applied.
fn[C] IdlePool::put(
  self : IdlePool[C],
  origin : String,
  user_agent : String?,
  conn : C,
  now~ : Int64,
) -> Array[C] {
  let rejected = self.sweep(now~)
  if self.closed || self.max_per_origin <= 0 || self.idle_max_ms <= 0 {
    rejected.push(conn)
    return rejected
  }
  let parked = self.parked.get_or_init(origin, () => [])
  if parked.length() >= self.max_per_origin {
    rejected.push(conn)
    return rejected
  }
  parked.push({ conn, user_agent, parked_at_ms: now, })
  rejected
}

///|
/// Closes the pool and hands back every parked connection.
fn[C] IdlePool::drain(self : IdlePool[C]) -> Array[C] {
  self.closed = true
  let conns = []
  for _, parked in self.parked {
    for idle in parked {
      conns.push(idle.conn)
    }
  }
  self.parked.clear()
  conns
}

///|
fn[C] IdlePool::count(self : IdlePool[C]) -> Int32 {
  let mut total = 0
  for _, parked in self.parked {
    total += parked.length()
  }
  total
}

///|
/// Takes a young idle connection parked under `key`, or dials one to
/// `origin` on `route`, as the `Dial` phase of `timer`, when there is none or
/// `fresh` is set. Idle connections under any key that outlived
/// `idle_max_ms` are closed on the way. The flag says whether the connection
/// was reused.
async fn AsyncTransport::checkout(
  self : AsyncTransport,
  key : String,
  origin : String,
  route : Route,
  user_agent : String?,
  fresh~ : Bool,
  timer : PhaseTimer,
) -> (@ahttp.Client, Bool) raise @http.HttpError {
  if self.pool.closed {
    raise @http.HttpError::Connect("transport closed")
  }
  if !fresh {
    let (reused, expired) = self.pool.take(
      key,
      user_agent,
      now=self.clock.now_unix_ms(),
    )
    for client in expired {
      client.close()
    }
    if reused is Some(client) {
      return (client, true)
    }
  }
  let client = timer.run(Dial, () => dial(origin, route, user_agent))
  (client, false)
}

///|
/// Parks a connection whose response body has been fully consumed, or closes
/// it when the transport is closed or the origin already holds enough. Idle
/// connections of any origin that outlived `idle_max_ms` are closed first.
fn AsyncTransport::checkin(
  self : AsyncTransport,
  key : String,
  user_agent : String?,
  client : @ahttp.Client,
) -> Unit {
  for
    rejected in self.pool.put(
      key,
      user_agent,
      client,
      now=self.clock.now_unix_ms(),
    ) {
    rejected.close()
  }
}

///|
/// Closes every idle connection and refuses further requests, and those
/// waiting for a connection slot, with `Connect("transport closed")`.
/// In-flight requests finish and their connections are closed instead of
/// parked.
///
/// ```mbt check
/// test {
///   let transport = @http_async.AsyncTransport::new()
///   transport.close()
///   assert_eq(transport.idle_connections(), 0)
/// }
/// ```
pub fn AsyncTransport::close(self : AsyncTransport) -> Unit {
  for client in self.pool.drain() {
    client.close()
  }
  self.slots.refuse_waiting()
}

///|
/// The number of parked keep-alive connections across all origins.
pub fn AsyncTransport::idle_connections(self : AsyncTransport) -> Int32 {
  self.pool.count()
}

///|
/// Whether a request may be sent again on a fresh connection after a reused
/// one failed before producing a response head: idempotent methods, or any
/// request carrying an `Idempotency-Key`, and only while its body can be sent
/// again (`Body::is_replayable`: bytes, or a stream not yet taken).
fn replayable(request : @http.Request) -> Bool {
  if !request.body.is_replayable() {
    return false
  }
  if request.headers.contains("idempotency-key") {
    return true
  }
  match request.http_method.to_lower() {
    "get" | "head" | "put" | "delete" | "options" | "trace" => true
    _ => false
  }
}

///|
/// Whether the connection can carry another request after this exchange: not
/// when the server asked to close it, not after `101 Switching Protocols`
/// (the connection speaks another protocol now, and through a forwarding
/// proxy it may be a tunnel to the origin), and not after a caller's
/// `CONNECT`, which turns it into a tunnel.
fn reusable(http_method : String, response : @ahttp.Response) -> Bool {
  !connection_close(response) &&
  response.code != 101 &&
  http_method.to_upper() != "CONNECT"
}

///|
/// Whether the server asked to close the connection after this response:
/// `Connection` is a comma-separated token list, so `close` must be a whole token.
fn connection_close(response : @ahttp.Response) -> Bool {
  guard response.headers.get(@ahttp.CaseInsensitiveString("connection"))
    is Some(value) else {
    return false
  }
  value.split(",").any(token => token.trim().to_owned().to_lower() == "close")
}
