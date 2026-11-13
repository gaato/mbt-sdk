// The in-memory pipe the white-box tests connect a Connection through, named
// in this file alone: core/async after MoonBit 0.10.20 renamed @io.pipe and
// its PipeRead and PipeWrite to memory_pipe, MemoryPipeRead and
// MemoryPipeWrite, with no alias. On such a toolchain the canary replaces this
// file with compat/core_async_next/jsonrpc-async/src/pipe_wbtest.mbt.next.

///|
/// A connected pair: what is written to the second end is read from the first.
fn test_pipe() -> (@io.PipeRead, @io.PipeWrite) {
  @io.pipe()
}
