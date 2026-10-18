///|
/// A native app-server subprocess and its initialized client.
pub struct Session {
  client : Client
  priv child : @rpc.Child
}

///|
/// Starts `codex app-server` over stdio. stderr is inherited, never protocol data.
/// Pass extra_env (for example CODEX_HOME) to isolate configuration if needed.
/// Child and pipe lifetime is bounded by the supplied task group.
/// `max_line` is passed to the connection as in `connect`.
pub async fn[X] spawn(
  group : @async.TaskGroup[X],
  initialize : @protocol.InitializeParams,
  program~ : String = "codex",
  cwd? : String,
  extra_env? : Map[String, String],
  handlers~ : Handlers = Handlers::new(),
  on_event~ : EventHandler = _ => (),
  timeout_ms~ : Int32 = 10000,
  max_line? : Int32,
) -> Session {
  let child = @rpc.spawn_child(
    group,
    program,
    ["app-server"],
    cwd?,
    extra_env?,
    envelope=Bare,
    max_line?,
    on_request=(name, params) => handlers.dispatch(name, params),
    on_notification=(name, params) => {
      on_event(@protocol.Event::decode(name, params))
    },
  )
  let client = initialize_connection(child.connection, initialize, timeout_ms~)
  { client, child, }
}

///|
/// Sends EOF and waits for exit, terminating the child after the timeout.
pub async fn Session::shutdown(
  self : Session,
  timeout_ms~ : Int32 = 5000,
) -> Int32 {
  self.child.shutdown(timeout_ms~)
}
