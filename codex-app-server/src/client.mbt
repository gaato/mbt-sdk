///|
/// Local protocol failures; transport and remote failures retain RpcFailure.
pub(all) suberror ClientError {
  AlreadyInitialized
  InvalidResult(String, String)
}

///|
/// An initialized app-server connection. Owned by the caller's task group.
pub struct Client {
  priv connection : @rpc.Connection
  info : @protocol.InitializeResponse
}

///|
/// Receives typed events in wire order. Callbacks may make RPC calls.
pub type EventHandler = async (@protocol.Event) -> Unit

///|
/// Completes the initialize/initialized handshake before returning a client.
/// The caller owns reader lifetime; close_writer must close the output stream.
/// Handshake failure closes the connection, including on cancellation.
pub async fn[X] connect(
  group : @async.TaskGroup[X],
  reader : &@io.Reader,
  writer : &@io.Writer,
  initialize : @protocol.InitializeParams,
  close_writer~ : () -> Unit,
  handlers? : Handlers = Handlers::new(),
  on_event? : EventHandler = _ => (),
  timeout_ms? : Int = 10000,
) -> Client {
  let connection = @rpc.Connection::start(
    group,
    reader,
    writer,
    close_writer~,
    envelope=Bare,
    on_request=(name, params) => handlers.dispatch(name, params),
    on_notification=(name, params) => {
      on_event(@protocol.Event::decode(name, params))
    },
  )
  initialize_connection(connection, initialize, timeout_ms~)
}

///|
async fn initialize_connection(
  connection : @rpc.Connection,
  params : @protocol.InitializeParams,
  timeout_ms~ : Int,
) -> Client {
  let mut ready = false
  defer (if !ready { connection.close() })
  let info = @async.with_timeout(
    timeout_ms,
    () => {
      let request = @protocol.initialize(params)
      let result = connection.call(request.name, params=request.params)
      let info = decode_result(request, result)
      connection.notify("initialized")
      info
    },
    error=@rpc.RpcFailure::Timeout(timeout_ms),
  )
  ready = true
  { connection, info, }
}

///|
fn[T] decode_result(
  request : @protocol.Call[T],
  value : Json,
) -> T raise ClientError {
  (request.decode)(value) catch {
    error => raise InvalidResult(request.name, error.to_string())
  }
}

///|
/// Sends a generated request and decodes its typed result. No automatic retry:
/// cancellation or timeout does not imply that the server stopped the turn.
/// Use turn_interrupt explicitly to stop model work.
pub async fn[T] Client::call(
  self : Client,
  request : @protocol.Call[T],
  timeout_ms? : Int,
) -> T {
  if request.name == "initialize" {
    raise AlreadyInitialized
  }
  let value = self.connection.call(
    request.name,
    params=request.params,
    timeout_ms?,
  )
  decode_result(request, value)
}

///|
/// Fails pending calls and closes the output stream. Does not wait for a child.
pub fn Client::close(self : Client) -> Unit {
  self.connection.close()
}

///|
/// Whether the underlying connection has ended or has been closed.
pub fn Client::is_closed(self : Client) -> Bool {
  self.connection.is_closed()
}
