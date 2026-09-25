///|
fn[X] pair(
  group : @async.TaskGroup[X],
  left_handler? : @jsonrpc_async.RequestHandler,
  right_handler? : @jsonrpc_async.RequestHandler,
  right_notification? : @jsonrpc_async.NotificationHandler,
) -> (@jsonrpc_async.Connection, @jsonrpc_async.Connection) {
  let (left_read, right_write) = @io.pipe()
  let (right_read, left_write) = @io.pipe()
  group.add_defer(() => {
    left_read.close()
    right_read.close()
    left_write.close()
    right_write.close()
  })
  let left = @jsonrpc_async.Connection::start(
    group,
    left_read,
    left_write,
    close_writer=() => left_write.close(),
    on_request?=left_handler,
  )
  let right = @jsonrpc_async.Connection::start(
    group,
    right_read,
    right_write,
    close_writer=() => right_write.close(),
    on_request?=right_handler,
    on_notification?=right_notification,
  )
  (left, right)
}

///|
async test "concurrent calls in both directions retain their ids" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let handler : @jsonrpc_async.RequestHandler = (name, params) => {
        @async.sleep(1)
        Ok({ "name": name, "params": params.unwrap() })
      }
      let (left, right) = pair(
        group,
        left_handler=handler,
        right_handler=handler,
      )
      let tasks = []
      for i in 0..<30 {
        tasks.push(
          group.spawn(() => {
            assert_eq(left.call("right", params=Json(i)), {
              "name": "right",
              "params": i,
            })
          }),
        )
        tasks.push(
          group.spawn(() => {
            assert_eq(right.call("left", params=Json(i)), {
              "name": "left",
              "params": i,
            })
          }),
        )
      }
      for task in tasks {
        task.wait()
      }
      assert_eq(left.decode_errors(), 0)
      assert_eq(right.decode_errors(), 0)
    })
  })
}

///|
async test "notifications run in FIFO order while requests remain responsive" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let received : @aqueue.Queue[Json] = @aqueue.Queue(kind=Unbounded)
      let release : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
      let (left, _) = pair(group, right_handler=(_, _) => Ok(true), right_notification=(
        _,
        params,
      ) => {
        if params == Some(Json(0)) {
          release.get()
        }
        @async.sleep(1)
        received.put(params.unwrap())
      })
      for i in 0..<100 {
        left.notify("update", params=Json(i))
      }
      assert_eq(left.call("ready"), true)
      release.put(())
      for i in 0..<100 {
        assert_eq(received.get(), Json(i))
      }
    })
  })
}

///|
async test "remote errors default method handler and call deadlines" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (left, right) = pair(group, right_handler=(name, _) => {
        if name == "wait" {
          @async.sleep(100)
        }
        Err(@jsonrpc.RpcError::invalid_params())
      })
      try left.call("bad") catch {
        @jsonrpc_async.RpcFailure::Remote(error) =>
          assert_eq(error.code, -32602)
        error => raise error
      } noraise {
        _ => fail("expected remote error")
      }
      try right.call("missing") catch {
        @jsonrpc_async.RpcFailure::Remote(error) => {
          assert_eq(error.code, -32601)
          assert_eq(error.data, Some(Json("missing")))
        }
        error => raise error
      } noraise {
        _ => fail("expected method not found")
      }
      try left.call("wait", timeout_ms=10) catch {
        @jsonrpc_async.RpcFailure::Timeout(ms) => assert_eq(ms, 10)
        error => raise error
      } noraise {
        _ => fail("expected timeout")
      }
      // The late response must not poison the next request.
      try left.call("bad") catch {
        @jsonrpc_async.RpcFailure::Remote(error) =>
          assert_eq(error.code, -32602)
        error => raise error
      } noraise {
        _ => fail("expected remote error")
      }
    })
  })
}

///|
async test "peer close fails pending and future calls and is idempotent" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
      let release : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
      let (left, right) = pair(group, right_handler=(_, _) => {
        started.put(())
        release.get()
        Ok(true)
      })
      let task = group.spawn(() => {
        try left.call("wait") catch {
          @jsonrpc_async.RpcFailure::Closed => ()
          error => raise error
        } noraise {
          _ => fail("expected closed pending call")
        }
      })
      started.get()
      right.close()
      right.close()
      task.wait()
      assert_true(left.is_closed())
      try left.call("later") catch {
        @jsonrpc_async.RpcFailure::Closed => ()
        error => raise error
      } noraise {
        _ => fail("expected closed new call")
      }
      // Cancel the waiting handler with its owning group.
      group.return_immediately(())
    })
  })
}

///|
async test "request handlers can call the peer without blocking the reader" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let mut peer : @jsonrpc_async.Connection? = None
      let (left, right) = pair(
        group,
        left_handler=(_, params) => Ok(params.unwrap()),
        right_handler=(_, params) => Ok(peer.unwrap().call("nested", params?)),
      )
      peer = Some(right)
      assert_eq(left.call("outer", params={ "hello": "world" }), {
        "hello": "world",
      })
    })
  })
}

///|
async test "garbage strict-envelope errors and unknown responses allow later calls" {
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
      let connection = @jsonrpc_async.Connection::start(group, read, write, on_request=(
        _,
        params,
      ) => Ok(params.unwrap_or(Json::null())))
      let lines = [
        b"plain text\n", b"{\"foo\":1}\n", b"{\"method\":\"bare\"}\n", b"\xff\n",
      ]
      for index, line in lines {
        peer_write.write(line)
        let reply = @jsonrpc.decode_line(
          @utf8.encode(peer_read.read_until("\n").unwrap()),
          envelope=Strict,
        )
        guard reply is Failure(id=Null, error~) else {
          fail("expected null-id error")
        }
        assert_eq(
          error.code,
          if index == 0 || index == 3 {
            -32700
          } else {
            -32600
          },
        )
      }
      peer_write.write(
        @jsonrpc.Message::Response(id=Number(999L), result=Json::null()).encode(
          envelope=Strict,
        ),
      )
      peer_write.write(
        @jsonrpc.Message::Request(id=Str("ok"), name="echo", params=Some(true)).encode(
          envelope=Strict,
        ),
      )
      let reply = @jsonrpc.decode_line(
        @utf8.encode(peer_read.read_until("\n").unwrap()),
        envelope=Strict,
      )
      assert_eq(reply, @jsonrpc.Message::Response(id=Str("ok"), result=true))
      assert_eq(connection.decode_errors(), 4)
    })
  })
}
