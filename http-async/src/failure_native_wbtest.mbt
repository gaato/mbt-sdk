///|
/// A failure that is neither an `HttpError` nor one the parser raises, as a
/// reset or a refused connection would be.
suberror Broken {
  Broken(String)
}

///|
impl Show for Broken with fn output(self, logger) {
  let Broken(message) = self
  logger.write_string(message)
}

///|
test "failure maps each phase's errors on native" {
  let rows : Array[(@http.Phase, Error, String)] = [
    // Before the connection is made nothing was sent.
    (Pool, Broken("odd"), "Connect(\"odd\")"),
    (Dial, Broken("refused"), "Connect(\"refused\")"),
    // After it, the connection's failures are Network in the phase seen.
    (
      Write,
      Broken("broken pipe"),
      "Network(phase=Write, message=\"broken pipe\")",
    ),
    (Head, @io.ReaderClosed, "Network(phase=Head, message=\"ReaderClosed\")"),
    (Body, Broken("reset"), "Network(phase=Body, message=\"reset\")"),
    (Unknown, Broken("reset"), "Network(phase=Unknown, message=\"reset\")"),
    // An HttpError passes through whatever the phase.
    (Body, @http.HttpError::Connect("closed"), "Connect(\"closed\")"),
    (Head, @http.HttpError::Protocol("bad"), "Protocol(\"bad\")"),
    (
      Body,
      @http.HttpError::Timeout(phase=Dial, ms=5),
      "Timeout(phase=Dial, ms=5)",
    ),
    (
      Write,
      @http.HttpError::Network(phase=Body, message="x"),
      "Network(phase=Body, message=\"x\")",
    ),
    (
      Body,
      @http.HttpError::Proxy(status=502, message="x"),
      "Proxy(status=502, message=\"x\")",
    ),
  ]
  for row in rows {
    let (phase, error, expected) = row
    assert_eq(@debug.to_string(failure(phase, error)), expected)
  }
}

///|
test "native reports every phase as it is" {
  for phase in [@http.Phase::Pool, Dial, Write, Head, Body, Unknown] {
    assert_eq(reported_phase(phase), phase)
  }
}
