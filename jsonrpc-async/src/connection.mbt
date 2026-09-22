///|
/// A remote RPC error, transport failure, call deadline, or closed connection.
///
/// ```mbt check
/// test {
///   let _ = @jsonrpc_async.RpcFailure::Timeout(1000)
/// }
/// ```
pub(all) suberror RpcFailure {
  Remote(@jsonrpc.RpcError)
  Transport(String)
  Timeout(Int)
  Closed
} derive(Debug)

///|
/// Formats RPC failures for diagnostics.
pub extend RpcFailure with @debug.Debug::{to_repr}

///|
/// Handles a request. Return `Err` for a protocol error; raising fails the group.
pub type RequestHandler = async (String, Json?) -> Result[
  Json,
  @jsonrpc.RpcError,
]

///|
/// Handles notifications sequentially in receive order.
pub type NotificationHandler = async (String, Json?) -> Unit

///|
/// A bidirectional NDJSON connection whose tasks belong to the supplied group.
pub struct Connection {
  priv writer : &@io.Writer
  priv close_writer : () -> Unit
  priv envelope : @jsonrpc.Envelope
  priv mutex : @async.Mutex
  priv pending : Map[@jsonrpc.RequestId, @aqueue.Queue[Json]]
  priv notifications : @aqueue.Queue[(String, Json?)]
  priv mut next_id : Int64
  priv mut closed : Bool
  priv mut writer_closed : Bool
  priv mut errors : Int
}

///|
/// Starts reading and dispatching in `group`. The caller owns the reader.
/// Supply `close_writer` to send EOF when closing; its default does nothing.
pub fn[X] Connection::start(
  group : @async.TaskGroup[X],
  reader : &@io.Reader,
  writer : &@io.Writer,
  close_writer? : () -> Unit = () => (),
  envelope? : @jsonrpc.Envelope = Strict,
  max_line? : Int,
  on_request? : RequestHandler = (name, _) => {
    Err(@jsonrpc.RpcError::method_not_found(name))
  },
  on_notification? : NotificationHandler = (_, _) => (),
) -> Connection {
  let self : Connection = {
    writer,
    close_writer,
    envelope,
    mutex: @async.Mutex(),
    pending: {},
    notifications: @aqueue.Queue(kind=Unbounded),
    next_id: 1L,
    closed: false,
    writer_closed: false,
    errors: 0,
  }
  group.spawn_bg(no_wait=true, () => {
    for ;; {
      let entry = self.notifications.get() catch {
        @aqueue.QueueAlreadyClosed => return
        error => raise error
      }
      on_notification(entry.0, entry.1)
    }
  })
  group.spawn_bg(no_wait=true, () => {
    defer self.end_reading()
    let framer = @jsonrpc.LineFramer::new(max_line?)
    let failure : Error? = try {
      for ;; {
        match reader.read_some() {
          Some(bytes) =>
            for line in framer.feed(bytes) {
              self.dispatch(group, line, on_request)
            }
          None => {
            if framer.finish() is Some(line) {
              self.dispatch(group, line, on_request)
            }
            break
          }
        }
      }
      None
    } catch {
      @jsonrpc.DecodeError::LineTooLong(limit) =>
        Some(RpcFailure::Transport("JSON-RPC line exceeds \{limit} bytes"))
      error => Some(error)
    }
    if failure is Some(error) {
      self.fail_pending(Transport(error.to_string()))
      raise error
    }
  })
  self
}

///|
fn Connection::fail_pending(self : Connection, error : RpcFailure) -> Unit {
  self.closed = true
  for _, queue in self.pending {
    queue.close(error~)
  }
  self.pending.clear()
}

///|
fn Connection::end_reading(self : Connection) -> Unit {
  self.fail_pending(Closed)
  self.notifications.close(clear=false)
}

///|
/// Closes the writer once and fails pending calls. The reader remains owned by
/// the caller; group cancellation stops the read task if the peer never sends EOF.
pub fn Connection::close(self : Connection) -> Unit {
  self.fail_pending(Closed)
  if !self.writer_closed {
    self.writer_closed = true
    (self.close_writer)()
  }
}

///|
/// Reports whether EOF, a transport failure, or explicit close ended the connection.
pub fn Connection::is_closed(self : Connection) -> Bool {
  self.closed
}

///|
/// Returns the number of malformed received records.
pub fn Connection::decode_errors(self : Connection) -> Int {
  self.errors
}

///|
async fn Connection::send(
  self : Connection,
  message : @jsonrpc.Message,
  reply? : Bool = false,
) -> Unit raise RpcFailure {
  if self.writer_closed || (self.closed && !reply) {
    raise Closed
  }
  self.mutex.acquire()
  defer self.mutex.release()
  if self.writer_closed || (self.closed && !reply) {
    raise Closed
  }
  let mut complete = false
  // A cancelled write may leave a partial line. Do not reuse that stream.
  defer (if !complete { self.close() })
  self.writer.write(message.encode(envelope=self.envelope)) catch {
    error => {
      let failure = RpcFailure::Transport(error.to_string())
      self.fail_pending(failure)
      raise failure
    }
  }
  complete = true
}

///|
/// Sends a request and waits for its matching response. Cancellation propagates
/// unchanged and removes the pending request. A deadline covers send and receive.
pub async fn Connection::call(
  self : Connection,
  name : String,
  params? : Json,
  timeout_ms? : Int,
) -> Json raise RpcFailure {
  if self.closed {
    raise Closed
  }
  if timeout_ms is Some(ms) && ms <= 0 {
    raise Timeout(ms)
  }
  let id = @jsonrpc.RequestId::Number(self.next_id)
  self.next_id += 1L
  let queue : @aqueue.Queue[Json] = @aqueue.Queue(kind=Unbounded)
  self.pending[id] = queue
  defer self.pending.remove(id)
  let run : async () -> Json = () => {
    self.send(Request(id~, name~, params~))
    queue.get()
  }
  try {
    match timeout_ms {
      None => run()
      Some(ms) => @async.with_timeout(ms, run, error=RpcFailure::Timeout(ms))
    }
  } catch {
    RpcFailure::Remote(error) => raise Remote(error)
    RpcFailure::Transport(message) => raise Transport(message)
    RpcFailure::Timeout(ms) => raise Timeout(ms)
    RpcFailure::Closed => raise Closed
    error => raise Transport(error.to_string())
  }
}

///|
/// Sends one notification without waiting for a response.
pub async fn Connection::notify(
  self : Connection,
  name : String,
  params? : Json,
) -> Unit raise RpcFailure {
  self.send(Notification(name~, params~))
}
