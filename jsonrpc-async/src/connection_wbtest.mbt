///|
test "sends are refused once the writer closes, and only replies outlive close" {
  // (writer_closed, closed, reply, refused)
  let rows : Array[(Bool, Bool, Bool, Bool)] = [
    (false, false, false, false),
    (false, false, true, false),
    (false, true, false, true),
    (false, true, true, false),
    (true, false, false, true),
    (true, false, true, true),
    (true, true, false, true),
    (true, true, true, true),
  ]
  for row in rows {
    let (writer_closed, closed, reply, refused) = row
    assert_eq(
      send_refused(writer_closed~, closed~, reply~),
      refused,
      msg="writer_closed=\{writer_closed} closed=\{closed} reply=\{reply}",
    )
  }
}

///|
test "a read failure reaches pending calls as Transport with a readable message" {
  let rows : Array[(String, Error, String)] = [
    (
      "a transport failure keeps its message",
      RpcFailure::Transport("JSON-RPC line exceeds 4 bytes"),
      "JSON-RPC line exceeds 4 bytes",
    ),
    (
      "any other error carries its text",
      Failure("boom"),
      Failure("boom").to_string(),
    ),
  ]
  for row in rows {
    let (label, error, expected) = row
    guard read_failure(error) is Transport(message) else {
      fail("\{label}: not Transport")
    }
    assert_eq(message, expected, msg=label)
  }
}
