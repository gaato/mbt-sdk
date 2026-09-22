///|
async test "cat round trip and graceful shutdown" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let received : @aqueue.Queue[Json] = @aqueue.Queue(kind=Unbounded)
      let child = @jsonrpc_async.spawn_child(
        group,
        "cat",
        [],
        on_request=(_, params) => Ok(params.unwrap()),
        on_notification=(_, params) => received.put(params.unwrap()),
      )
      child.connection.notify("update", params={ "n": 1 })
      assert_eq(received.get(), { "n": 1 })
      assert_eq(child.connection.call("echo", params=[1, 2, 3]), [1, 2, 3])
      assert_eq(child.shutdown(), 0)
      assert_eq(child.shutdown(), 0)
    })
  })
}

///|
async test "shutdown cancels a child that does not exit on stdin EOF" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let child = @jsonrpc_async.spawn_child(group, "sleep", ["60"])
      let code = child.shutdown(timeout_ms=20)
      assert_true(code != 0)
      assert_eq(child.process.try_wait(), Some(code))
    })
  })
}
