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
      let reply = match error {
        @jsonrpc.DecodeError::InvalidJson(_) => @jsonrpc.RpcError::parse_error()
        @jsonrpc.DecodeError::InvalidMessage(_) =>
          @jsonrpc.RpcError::invalid_request()
        @jsonrpc.DecodeError::LineTooLong(_) => raise error
      }
      group.spawn_bg(() => self.send(Failure(id=Null, error=reply), reply=true))
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
        let result = match outcome {
          Ok(result) => result
          Err(error) => {
            self.send(
              Failure(
                id~,
                error=@jsonrpc.RpcError::internal_error(
                  message=error.to_string(),
                ),
              ),
              reply=true,
            ) catch {
              _ => ()
            }
            raise error
          }
        }
        match result {
          Ok(result) => self.send(Response(id~, result~), reply=true)
          Err(error) => self.send(Failure(id~, error~), reply=true)
        }
      })
    Notification(name~, params~) =>
      ignore(self.notifications.try_put((name, params)))
  }
}
