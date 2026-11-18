///|
fn pipes(
  group : @async.TaskGroup,
) -> (
  @io.MemoryPipeRead,
  @io.MemoryPipeWrite,
  @io.MemoryPipeRead,
  @io.MemoryPipeWrite,
) {
  let (client_read, server_write) = @io.memory_pipe()
  let (server_read, client_write) = @io.memory_pipe()
  group.add_defer(() => {
    client_read.close()
    client_write.close()
    server_read.close()
    server_write.close()
  })
  (client_read, client_write, server_read, server_write)
}
