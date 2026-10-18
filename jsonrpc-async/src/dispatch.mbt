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
/// The reply to a request refused because `max_inbound` are being handled:
/// the error Codex's app-server gives when its own request ingress is full.
fn overloaded_reply(id : @jsonrpc.RequestId) -> @jsonrpc.Message {
  Failure(
    id~,
    error=@jsonrpc.RpcError::new(
      code=-32001,
      message="Server overloaded; retry later.",
    ),
  )
}

///|
/// Sends a reply that needs no handler from a task of its own. At most
/// `max_inbound` wait to be written; past that the read loop waits for one to
/// finish, which depends on the peer reading and never on a handler.
async fn[X] Connection::reply_later(
  self : Connection,
  group : @async.TaskGroup[X],
  reply : @jsonrpc.Message,
) -> Unit {
  self.replies.acquire()
  group.spawn_bg(() => {
    defer self.replies.release()
    self.send(reply, reply=true)
  })
}

///|
/// Routes one received line. It waits only in `reply_later`: a handler that
/// awaits a call's response needs this loop to keep reading, so a request past
/// `max_inbound` is refused rather than waited for.
async fn[X] Connection::dispatch(
  self : Connection,
  group : @async.TaskGroup[X],
  line : Bytes,
  on_request : RequestHandler,
) -> Unit {
  let message = @jsonrpc.decode_line(line, envelope=self.envelope) catch {
    error => {
      self.errors += 1
      guard decode_failure_reply(error) is Some(reply) else { raise error }
      self.reply_later(group, reply)
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
      if self.handlers.try_acquire() {
        group.spawn_bg(() => {
          defer self.handlers.release()
          let outcome = Ok(on_request(name, params)) catch {
            error => Err(error)
          }
          let reply = request_reply(id, outcome)
          if outcome is Err(error) {
            self.send(reply, reply=true) catch {
              _ => ()
            }
            raise error
          }
          self.send(reply, reply=true)
        })
      } else {
        self.reply_later(group, overloaded_reply(id))
      }
    Notification(name~, params~) =>
      if !self.notifications.try_put((name, params)) {
        raise RpcFailure::Transport(
          "JSON-RPC notification backlog exceeds \{self.max_notifications} notifications",
        )
      }
  }
}
