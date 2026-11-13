// The in-memory pipes the black-box tests connect a client and a fake server
// through, named in this file alone: core/async after MoonBit 0.10.20 renamed
// @io.pipe and its PipeRead and PipeWrite to memory_pipe, MemoryPipeRead and
// MemoryPipeWrite, with no alias. On such a toolchain the canary replaces this
// file with compat/core_async_next/codex-app-server/src/pipe_test.mbt.next.

///|
fn pipes(
  group : @async.TaskGroup,
) -> (@io.PipeRead, @io.PipeWrite, @io.PipeRead, @io.PipeWrite) {
  let (client_read, server_write) = @io.pipe()
  let (server_read, client_write) = @io.pipe()
  group.add_defer(() => {
    client_read.close()
    client_write.close()
    server_read.close()
    server_write.close()
  })
  (client_read, client_write, server_read, server_write)
}
