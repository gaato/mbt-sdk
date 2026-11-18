///|
/// A connected pair: what is written to the second end is read from the first.
fn test_pipe() -> (@io.MemoryPipeRead, @io.MemoryPipeWrite) {
  @io.memory_pipe()
}
