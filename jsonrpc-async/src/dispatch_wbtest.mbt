///|
test "decode failures map to id-null replies except overlong lines" {
  let rows : Array[(String, @jsonrpc.DecodeError, @jsonrpc.Message?)] = [
    (
      "invalid JSON is a parse error",
      InvalidJson("eof"),
      Some(Failure(id=Null, error=@jsonrpc.RpcError::parse_error())),
    ),
    (
      "invalid message is an invalid request",
      InvalidMessage("no method"),
      Some(Failure(id=Null, error=@jsonrpc.RpcError::invalid_request())),
    ),
    ("an overlong line is fatal", LineTooLong(8), None),
  ]
  for row in rows {
    let (label, error, expected) = row
    assert_eq(decode_failure_reply(error), expected, msg=label)
  }
}

///|
test "request outcomes map to responses and failures" {
  let protocol = @jsonrpc.RpcError::invalid_params()
  let rows : Array[
    (String, Result[Result[Json, @jsonrpc.RpcError], Error], @jsonrpc.Message),
  ] = [
    (
      "a result is a response",
      Ok(Ok(Json::number(1))),
      Response(id=Number(7L), result=Json::number(1)),
    ),
    (
      "a protocol error is a failure carrying it",
      Ok(Err(protocol)),
      Failure(id=Number(7L), error=protocol),
    ),
    (
      "a raised error is an internal error with its text",
      Err(Failure("boom")),
      Failure(
        id=Number(7L),
        error=@jsonrpc.RpcError::internal_error(
          message=Failure("boom").to_string(),
        ),
      ),
    ),
  ]
  for row in rows {
    let (label, outcome, expected) = row
    assert_eq(request_reply(Number(7L), outcome), expected, msg=label)
  }
}
