///|
fn parse_json(text : String) -> Json raise {
  @json.parse(text)
}

///|
fn decode(
  text : String,
  envelope : @jsonrpc.Envelope,
) -> @jsonrpc.Message raise {
  @jsonrpc.decode_line(@utf8.encode(text), envelope~)
}

///|
fn assert_round_trip(
  message : @jsonrpc.Message,
  envelope : @jsonrpc.Envelope,
) -> Unit raise {
  assert_eq(
    @jsonrpc.Message::from_json(message.to_json(envelope~), envelope~),
    message,
  )
  assert_eq(@jsonrpc.decode_line(message.encode(envelope~), envelope~), message)
}

///|
fn assert_invalid_message(
  text : String,
  envelope : @jsonrpc.Envelope,
) -> Unit raise {
  try decode(text, envelope) catch {
    @jsonrpc.DecodeError::InvalidMessage(_) => ()
    _ => fail("expected InvalidMessage")
  } noraise {
    _ => fail("expected InvalidMessage")
  }
}

///|
test "jsonrpc.org strict examples and round trips" {
  let examples = [
    (
      "{\"jsonrpc\":\"2.0\",\"method\":\"subtract\",\"params\":[42,23],\"id\":1}",
      @jsonrpc.Message::Request(
        id=@jsonrpc.RequestId::Number(1L),
        name="subtract",
        params=Some(parse_json("[42,23]")),
      ),
    ),
    (
      "{\"jsonrpc\":\"2.0\",\"method\":\"subtract\",\"params\":{\"subtrahend\":23,\"minuend\":42},\"id\":3}",
      @jsonrpc.Message::Request(
        id=@jsonrpc.RequestId::Number(3L),
        name="subtract",
        params=Some(parse_json("{\"subtrahend\":23,\"minuend\":42}")),
      ),
    ),
    (
      "{\"jsonrpc\":\"2.0\",\"method\":\"update\",\"params\":[1,2,3,4,5]}",
      @jsonrpc.Message::Notification(
        name="update",
        params=Some(parse_json("[1,2,3,4,5]")),
      ),
    ),
    (
      "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"error\":{\"code\":-32601,\"message\":\"Method not found\",\"data\":\"foobar\"}}",
      @jsonrpc.Message::Failure(
        id=@jsonrpc.RequestId::Str("1"),
        error=@jsonrpc.RpcError::method_not_found("foobar"),
      ),
    ),
  ]
  for pair in examples {
    let (text, expected) = pair
    assert_eq(decode(text, Strict), expected)
    assert_round_trip(expected, Strict)
  }
  try
    decode(
      "{\"jsonrpc\":\"2.0\",\"method\":\"foobar,\"params\":\"bar\",\"baz]",
      Strict,
    )
  catch {
    @jsonrpc.DecodeError::InvalidJson(_) => ()
    _ => fail("expected InvalidJson")
  } noraise {
    _ => fail("expected InvalidJson")
  }
  assert_invalid_message(
    "{\"jsonrpc\":\"2.0\",\"method\":1,\"params\":\"bar\"}",
    Strict,
  )
}

///|
test "bare codex shape accepts trace and arbitrary params" {
  let text = "{\"id\":\"turn-1\",\"method\":\"turn/start\",\"params\":true,\"trace\":{\"traceparent\":\"00-x\"}}"
  let expected = @jsonrpc.Message::Request(
    id=@jsonrpc.RequestId::Str("turn-1"),
    name="turn/start",
    params=Some(Json::boolean(true)),
  )
  assert_eq(decode(text, Bare), expected)
  assert_round_trip(expected, Bare)
  assert_invalid_message(text, Strict)
  assert_eq(
    decode("{\"jsonrpc\":\"2.0\",\"method\":\"ready\"}", Bare),
    @jsonrpc.Message::Notification(name="ready", params=None),
  )
  assert_invalid_message("{\"jsonrpc\":\"1.0\",\"method\":\"ready\"}", Bare)
}

///|
test "request id cases and response shape validation" {
  let cases = [
    ("0", @jsonrpc.RequestId::Number(0L)),
    ("-7", @jsonrpc.RequestId::Number(-7L)),
    ("\"abc\"", @jsonrpc.RequestId::Str("abc")),
    ("null", @jsonrpc.RequestId::Null),
  ]
  for pair in cases {
    let (text, expected) = pair
    let message = decode(
      "{\"jsonrpc\":\"2.0\",\"id\":" + text + ",\"result\":null}",
      Strict,
    )
    assert_eq(
      message,
      @jsonrpc.Message::Response(id=expected, result=Json::null()),
    )
  }
  for id in ["1.5", "true", "{}"] {
    assert_invalid_message(
      "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":null}",
      Strict,
    )
  }
  assert_invalid_message(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}",
    Strict,
  )
  assert_invalid_message("{\"jsonrpc\":\"2.0\",\"id\":1}", Strict)
  assert_invalid_message("{\"jsonrpc\":\"2.0\",\"result\":1}", Strict)
  assert_invalid_message("[]", Strict)
}

///|
test "reserved errors and invalid error objects" {
  assert_eq(@jsonrpc.RpcError::parse_error().code, -32700)
  assert_eq(@jsonrpc.RpcError::invalid_request().message, "Invalid Request")
  assert_eq(@jsonrpc.RpcError::invalid_params(message="bad").message, "bad")
  assert_eq(@jsonrpc.RpcError::internal_error().data, None)
  for
    error in [
      "{\"message\":\"missing code\"}", "{\"code\":-1}", "{\"code\":1.5,\"message\":\"fraction\"}",
      "{\"code\":1,\"message\":false}",
    ] {
    assert_invalid_message(
      "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":" + error + "}",
      Strict,
    )
  }
}

///|
test "encoded record has exactly one final raw newline" {
  let message = @jsonrpc.Message::Notification(
    name="log",
    params=Some(Json::string("first\nsecond\r\n last")),
  )
  let bytes = message.encode(envelope=Strict)
  assert_true(bytes.length() > 0)
  assert_eq(bytes[bytes.length() - 1], b'\n')
  for i in 0..<(bytes.length() - 1) {
    assert_true(bytes[i] != b'\n')
  }
  assert_eq(@jsonrpc.decode_line(bytes, envelope=Strict), message)
}

///|
test "invalid UTF-8 is InvalidJson" {
  try @jsonrpc.decode_line(b"\xff", envelope=Strict) catch {
    @jsonrpc.DecodeError::InvalidJson(_) => ()
    _ => fail("expected InvalidJson")
  } noraise {
    _ => fail("expected InvalidJson")
  }
}
