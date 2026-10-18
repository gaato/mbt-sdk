///|
/// A rejected fetch or an errored body stream.
suberror Broken {
  Broken(String)
}

///|
impl Show for Broken with fn output(self, logger) {
  let Broken(message) = self
  logger.write_string(message)
}

///|
test "failure maps each phase's errors on JS" {
  let rows : Array[(@http.Phase, Error, String)] = [
    (Dial, Broken("odd"), "Connect(\"odd\")"),
    // The head is awaited in the fetch call that also connects and sends,
    // and fetch does not say how it failed: never Connect, never Protocol.
    (
      Head,
      Broken("TypeError: fetch failed"),
      "Network(phase=Unknown, message=\"TypeError: fetch failed\")",
    ),
    (Body, Broken("terminated"), "Network(phase=Body, message=\"terminated\")"),
    (Body, @io.ReaderClosed, "Network(phase=Body, message=\"ReaderClosed\")"),
    (Head, @http.HttpError::Protocol("bad"), "Protocol(\"bad\")"),
  ]
  for row in rows {
    let (phase, error, expected) = row
    assert_eq(@debug.to_string(failure(phase, error)), expected)
  }
}

///|
test "JS reports the fetch call's phase as Unknown" {
  let rows : Array[(@http.Phase, @http.Phase)] = [
    (Pool, Pool),
    (Dial, Dial),
    (Write, Write),
    (Head, Unknown),
    (Body, Body),
    (Unknown, Unknown),
  ]
  for row in rows {
    assert_eq(reported_phase(row.0), row.1)
  }
}
