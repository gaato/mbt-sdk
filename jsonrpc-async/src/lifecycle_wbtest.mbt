///|
async test "cancellation bypasses catch removes pending and ignores late reply" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (read, peer_write) = @io.pipe()
      let (peer_read, write) = @io.pipe()
      group.add_defer(() => {
        read.close()
        write.close()
        peer_read.close()
        peer_write.close()
      })
      let connection = Connection::start(group, read, write)
      let mut caught = false
      let mut cleaned = false
      let task = group.spawn(allow_failure=true, () => {
        defer {
          cleaned = true
        }
        ignore(
          connection.call("cancel") catch {
            _ => {
              caught = true
              Json::null()
            }
          },
        )
      })
      ignore(peer_read.read_until("\n"))
      assert_eq(connection.pending.length(), 1)
      task.cancel()
      // Waiting on an explicitly cancelled task reports
      // WaitedTaskAlreadyCancelled. The catch inside the cancelled call itself
      // must still remain untouched.
      task.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => raise error
      }
      assert_true(cleaned)
      assert_false(caught)
      assert_eq(connection.pending.length(), 0)
      peer_write.write(
        @jsonrpc.Message::Response(id=Number(1L), result=true).encode(
          envelope=Strict,
        ),
      )
      assert_eq(connection.decode_errors(), 0)
      let next = group.spawn(() => connection.call("next"))
      ignore(peer_read.read_until("\n"))
      peer_write.write(
        @jsonrpc.Message::Response(id=Number(2L), result=false).encode(
          envelope=Strict,
        ),
      )
      assert_eq(next.wait(), false)
      assert_eq(connection.pending.length(), 0)
    })
  })
}

///|
async test "EOF decodes an unterminated response and preserves its result" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (read, peer_write) = @io.pipe()
      let (peer_read, write) = @io.pipe()
      group.add_defer(() => {
        read.close()
        write.close()
        peer_read.close()
        peer_write.close()
      })
      let mut closes = 0
      let connection = Connection::start(group, read, write, close_writer=() => {
        closes += 1
        write.close()
      })
      let task = group.spawn(() => connection.call("tail"))
      ignore(peer_read.read_until("\n"))
      peer_write.write(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}")
      peer_write.close()
      assert_eq(task.wait(), Json::null())
      assert_true(connection.is_closed())
      connection.close()
      connection.close()
      assert_eq(closes, 1)
      assert_eq(connection.pending.length(), 0)
    })
  })
}

///|
async test "write failure is Transport and clears all pending requests" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (read, peer_write) = @io.pipe()
      let (peer_read, write) = @io.pipe()
      group.add_defer(() => {
        read.close()
        write.close()
        peer_write.close()
      })
      peer_read.close()
      let connection = Connection::start(group, read, write)
      try connection.call("broken") catch {
        RpcFailure::Transport(_) => ()
        error => raise error
      } noraise {
        _ => fail("expected Transport")
      }
      assert_true(connection.is_closed())
      assert_eq(connection.pending.length(), 0)
    })
  })
}

///|
async test "LineTooLong fails pending requests with Transport and exits the group" {
  @async.with_timeout(5000, () => {
    let mut connection : Connection? = None
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
        let rpc = Connection::start(group, read, write, max_line=4)
        connection = Some(rpc)
        group.spawn_bg(() => {
          ignore(peer_read.read_until("\n"))
          peer_write.write(b"12345")
        })
        ignore(rpc.call("pending"))
      })
    catch {
      RpcFailure::Transport(_) => ()
      error => raise error
    } noraise {
      _ => fail("expected failed group")
    }
    assert_true(connection.unwrap().is_closed())
    assert_eq(connection.unwrap().pending.length(), 0)
  })
}
