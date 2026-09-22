///|
/// Encodes a message as a JSON object using the selected envelope mode.
///
/// ```mbt check
/// test {
///   let message = @jsonrpc.Message::Response(id=@jsonrpc.RequestId::Number(1L), result={
///     "ok": true,
///   })
///   assert_eq(
///     message.to_json(envelope=@jsonrpc.Envelope::Strict).stringify(),
///     "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}",
///   )
/// }
/// ```
pub fn Message::to_json(self : Message, envelope~ : Envelope) -> Json {
  let fields : Map[String, Json] = Map([])
  if envelope is Strict {
    fields["jsonrpc"] = Json::string("2.0")
  }
  match self {
    Request(id~, name=method_name, params~) => {
      fields["id"] = id.to_json()
      fields["method"] = Json::string(method_name)
      if params is Some(value) {
        fields["params"] = value
      }
    }
    Notification(name=method_name, params~) => {
      fields["method"] = Json::string(method_name)
      if params is Some(value) {
        fields["params"] = value
      }
    }
    Response(id~, result~) => {
      fields["id"] = id.to_json()
      fields["result"] = result
    }
    Failure(id~, error~) => {
      fields["id"] = id.to_json()
      fields["error"] = error.to_json()
    }
  }
  Json::object(fields)
}

///|
/// Decodes a JSON-RPC message using the selected envelope mode.
pub fn Message::from_json(
  value : Json,
  envelope~ : Envelope,
) -> Message raise DecodeError {
  guard value is Object(fields) else {
    raise InvalidMessage("expected a JSON object; batches are unsupported")
  }
  validate_envelope(fields, envelope)
  match fields.get("method") {
    Some(String(method_name)) => {
      let params = fields.get("params")
      match fields.get("id") {
        Some(id) => Request(id=decode_id(id), name=method_name, params~)
        None => Notification(name=method_name, params~)
      }
    }
    Some(_) => raise InvalidMessage("method must be a string")
    None => decode_response(fields)
  }
}

///|
fn validate_envelope(
  fields : Map[String, Json],
  envelope : Envelope,
) -> Unit raise DecodeError {
  match fields.get("jsonrpc") {
    Some(String("2.0")) => ()
    None if envelope is Bare => ()
    None => raise InvalidMessage("missing jsonrpc member")
    Some(_) => raise InvalidMessage("jsonrpc must be \"2.0\"")
  }
}

///|
fn decode_id(value : Json) -> RequestId raise DecodeError {
  @json.from_json(value) catch {
    error => raise InvalidMessage(error.to_string())
  }
}

///|
fn decode_rpc_error(value : Json) -> RpcError raise DecodeError {
  @json.from_json(value) catch {
    error => raise InvalidMessage(error.to_string())
  }
}

///|
fn decode_response(fields : Map[String, Json]) -> Message raise DecodeError {
  guard fields.get("id") is Some(raw_id) else {
    raise InvalidMessage("response is missing id")
  }
  let id = decode_id(raw_id)
  match (fields.get("result"), fields.get("error")) {
    (Some(result), None) => Response(id~, result~)
    (None, Some(error)) => Failure(id~, error=decode_rpc_error(error))
    (Some(_), Some(_)) =>
      raise InvalidMessage("response cannot contain both result and error")
    (None, None) => raise InvalidMessage("response requires result or error")
  }
}

///|
/// Encodes a message as one compact newline-terminated NDJSON record.
pub fn Message::encode(self : Message, envelope~ : Envelope) -> Bytes {
  @utf8.encode(self.to_json(envelope~).stringify() + "\n")
}

///|
/// Decodes one UTF-8 JSON-RPC line.
pub fn decode_line(
  line : Bytes,
  envelope~ : Envelope,
) -> Message raise DecodeError {
  let text = @utf8.decode(line) catch {
    _ => raise InvalidJson("invalid UTF-8")
  }
  let value = @json.parse(text) catch {
    error => raise InvalidJson(error.to_string())
  }
  Message::from_json(value, envelope~)
}
