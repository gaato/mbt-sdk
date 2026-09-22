///|
suberror HandlerBug {
  HandlerBug
}

///|
struct RecordedWriter {
  bytes : Array[Byte]
}

///|
impl @io.Writer for RecordedWriter with fn write_once(
  self,
  bytes,
  offset~,
  len~,
) {
  for i in offset..<(offset + len) {
    self.bytes.push(bytes[i])
  }
  len
}

///|
async test "raising request handler replies internal error then fails the group" {
  @async.with_timeout(5000, () => {
    let output : RecordedWriter = { bytes: [], }
    try
      @async.with_task_group(group => {
        let (reader, writer) = @io.pipe()
        group.add_defer(() => {
          reader.close()
          writer.close()
        })
        let _ = @jsonrpc_async.Connection::start(group, reader, output, on_request=(
          _,
          _,
        ) => raise HandlerBug)
        writer.write(
          @jsonrpc.Message::Request(id=Number(1L), name="bug", params=None).encode(
            envelope=Strict,
          ),
        )
        @async.sleep(1000)
      })
    catch {
      HandlerBug => ()
      error => raise error
    } noraise {
      _ => fail("handler error must escape the group")
    }
    let reply = @jsonrpc.decode_line(
      Bytes::from_array(output.bytes),
      envelope=Strict,
    )
    guard reply is Failure(id=Number(1L), error~) else {
      fail("missing error response")
    }
    assert_eq(error.code, -32603)
  })
}

///|
async test "raising notification handler fails the group" {
  @async.with_timeout(5000, () => {
    try
      @async.with_task_group(group => {
        let (reader, writer) = @io.pipe()
        let output : RecordedWriter = { bytes: [], }
        group.add_defer(() => {
          reader.close()
          writer.close()
        })
        let _ = @jsonrpc_async.Connection::start(group, reader, output, on_notification=(
          _,
          _,
        ) => raise HandlerBug)
        writer.write(
          @jsonrpc.Message::Notification(name="bug", params=None).encode(
            envelope=Strict,
          ),
        )
        @async.sleep(1000)
      })
    catch {
      HandlerBug => ()
      error => raise error
    } noraise {
      _ => fail("notification error must escape the group")
    }
  })
}

///|
async test "EOF still permits a response to the final unterminated request" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let (reader, writer) = @io.pipe()
      let (reply_reader, reply_writer) = @io.pipe()
      group.add_defer(() => {
        reader.close()
        writer.close()
        reply_reader.close()
        reply_writer.close()
      })
      let rpc = @jsonrpc_async.Connection::start(group, reader, reply_writer, on_request=(
        _,
        _,
      ) => {
        @async.sleep(1)
        Ok(true)
      })
      writer.write(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"last\"}")
      writer.close()
      let reply = @jsonrpc.decode_line(
        @utf8.encode(reply_reader.read_until("\n").unwrap()),
        envelope=Strict,
      )
      assert_eq(reply, @jsonrpc.Message::Response(id=Number(1L), result=true))
      assert_true(rpc.is_closed())
    })
  })
}
