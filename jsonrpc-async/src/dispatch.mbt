///|
/// Returns the `id: null` reply to a line that failed to decode, or `None`
/// when the failure is fatal: an overlong line means the stream is broken.
fn decode_failure_reply(error : @jsonrpc.DecodeError) -> @jsonrpc.Message? {
  let reply = match error {
    InvalidJson(_) => @jsonrpc.RpcError::parse_error()
    InvalidMessage(_) => @jsonrpc.RpcError::invalid_request()
    LineTooLong(_) => return None
  }
  Some(Failure(id=Null, error=reply))
}

///|
/// Builds the reply to request `id` from its handler outcome. A raising handler
/// is answered with an internal error before the raise fails the group.
fn request_reply(
  id : @jsonrpc.RequestId,
  outcome : Result[Result[Json, @jsonrpc.RpcError], Error],
) -> @jsonrpc.Message {
  match outcome {
    Ok(Ok(result)) => Response(id~, result~)
    Ok(Err(error)) => Failure(id~, error~)
    Err(error) =>
      Failure(
        id~,
        error=@jsonrpc.RpcError::internal_error(message=error.to_string()),
      )
  }
}

///|
fn[X] Connection::dispatch(
  self : Connection,
  group : @async.TaskGroup[X],
  line : Bytes,
  on_request : RequestHandler,
) -> Unit raise {
  let message = @jsonrpc.decode_line(line, envelope=self.envelope) catch {
    error => {
      self.errors += 1
      guard decode_failure_reply(error) is Some(reply) else { raise error }
      group.spawn_bg(() => self.send(reply, reply=true))
      return
    }
  }
  match message {
    Response(id~, result~) =>
      if self.pending.get(id) is Some(queue) {
        self.pending.remove(id)
        ignore(queue.try_put(result))
      }
    Failure(id~, error~) =>
      if self.pending.get(id) is Some(queue) {
        self.pending.remove(id)
        queue.close(error=RpcFailure::Remote(error))
      }
    Request(id~, name~, params~) =>
      group.spawn_bg(() => {
        let outcome = Ok(on_request(name, params)) catch { error => Err(error) }
        let reply = request_reply(id, outcome)
        if outcome is Err(error) {
          self.send(reply, reply=true) catch {
            _ => ()
          }
          raise error
        }
        self.send(reply, reply=true)
      })
    Notification(name~, params~) =>
      ignore(self.notifications.try_put((name, params)))
  }
}
