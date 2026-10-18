// Native only: 64 MiB through the in-memory pipe takes thousands of scheduler
// rounds, which the JS event loop runs too slowly for the test deadline.

///|
async test "lines are limited to 64 MiB when max_line is omitted" {
  @async.with_timeout(5000, () => {
    let limit = 64 * 1024 * 1024
    let mut message = ""
    try
      @async.with_task_group(group => {
        let (read, peer_write) = @io.pipe()
        let (peer_read, write) = @io.pipe()
        group.add_defer(() => {
          read.close()
          peer_write.close()
          peer_read.close()
          write.close()
        })
        let rpc = Connection::start(group, read, write)
        group.spawn_bg(() => {
          ignore(peer_read.read_until("\n"))
          let chunk = Bytes::make(1024 * 1024, b'x')
          for _ in 0..<(limit / chunk.length()) {
            peer_write.write(chunk)
          }
          peer_write.write(b"x")
        })
        ignore(rpc.call("pending"))
      })
    catch {
      RpcFailure::Transport(text) => message = text
      error => raise error
    } noraise {
      _ => fail("expected failed group")
    }
    assert_eq(message, "JSON-RPC line exceeds \{limit} bytes")
  })
}

///|
async test "the notification backlog is limited to 32,768 when max_notifications is omitted" {
  @async.with_timeout(5000, () => {
    let limit = 32_768
    let mut message = ""
    try
      @async.with_task_group(group => {
        let (read, peer_write) = @io.pipe()
        let (peer_read, write) = @io.pipe()
        group.add_defer(() => {
          read.close()
          peer_write.close()
          peer_read.close()
          write.close()
        })
        let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
        let release : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
        let rpc = Connection::start(group, read, write, on_notification=(_, _) => {
          started.put(())
          release.get()
        })
        let tick = @jsonrpc.Message::Notification(name="tick", params=None).encode(
          envelope=Strict,
        )
        peer_write.write(tick)
        // The handler now holds the first; the rest fill the backlog exactly.
        started.get()
        let backlog : Array[Byte] = []
        for _ in 0..<limit {
          backlog.append(tick.to_array())
        }
        peer_write.write(Bytes::from_array(backlog))
        assert_false(rpc.is_closed())
        peer_write.write(tick)
        // Nothing is ever put: only the failing group ends this wait.
        release.get()
      })
    catch {
      RpcFailure::Transport(text) => message = text
      error => raise error
    } noraise {
      _ => fail("expected failed group")
    }
    assert_eq(
      message,
      "JSON-RPC notification backlog exceeds \{limit} notifications",
    )
  })
}
