///|
/// A native child process and its bidirectional JSON-RPC connection.
pub struct Child {
  connection : Connection
  process : @process.Process
}

///|
/// Starts a child with NDJSON on stdin/stdout. Stderr is inherited by default.
/// The limits and handlers are passed to `Connection::start`.
pub async fn[X] spawn_child(
  group : @async.TaskGroup[X],
  program : String,
  args : Array[String],
  cwd? : String,
  extra_env? : Map[String, String],
  stderr? : &@process.ProcessOutput,
  envelope~ : @jsonrpc.Envelope = Strict,
  max_line? : Int32,
  max_notifications? : Int32,
  max_inbound? : Int32,
  on_request? : RequestHandler,
  on_notification? : NotificationHandler,
) -> Child {
  let (stdin, writer) = @process.write_to_process()
  errdefer writer.close()
  let (reader, stdout) = @process.read_from_process()
  errdefer reader.close()
  let process = @process.spawn(
    group,
    program,
    args,
    stdin~,
    stdout~,
    stderr?,
    cwd?=cwd.map(value => value[:]),
    extra_env?,
  )
  group.add_defer(() => {
    writer.close()
    reader.close()
  })
  let connection = Connection::start(
    group,
    reader,
    writer,
    close_writer=() => writer.close(),
    envelope~,
    max_line?,
    max_notifications?,
    max_inbound?,
    on_request?,
    on_notification?,
  )
  { connection, process, }
}

///|
/// Sends EOF and waits for exit. After the deadline, cancels the child and waits
/// for it to terminate before returning its exit code.
pub async fn Child::shutdown(self : Child, timeout_ms~ : Int32 = 5000) -> Int32 {
  self.connection.close()
  if timeout_ms <= 0 {
    self.process.cancel()
    return self.process.wait()
  }
  @async.with_timeout(
    timeout_ms,
    () => self.process.wait(),
    error=RpcFailure::Timeout(timeout_ms),
  ) catch {
    RpcFailure::Timeout(_) => {
      self.process.cancel()
      self.process.wait()
    }
    error => raise error
  }
}
