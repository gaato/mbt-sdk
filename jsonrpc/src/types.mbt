///|
/// An identifier carried by a JSON-RPC request or response.
///
/// ```mbt check
/// test {
///   assert_eq(
///     @jsonrpc.RequestId::Str("request-1"),
///     @jsonrpc.RequestId::Str("request-1"),
///   )
/// }
/// ```
pub(all) enum RequestId {
  Number(Int64)
  Str(String)
  Null
} derive(Eq, Debug, Hash)

///|
/// Compares request identifiers.
pub extend RequestId with Eq::{equal, not_equal}

///|
/// Hashes request identifiers.
pub extend RequestId with Hash::{hash, hash_combine}

///|
/// Formats request identifiers for debugging.
pub extend RequestId with @debug.Debug::{to_repr}

///|
/// Encodes a request identifier as JSON.
pub extend RequestId with ToJson::{to_json}

///|
pub impl ToJson for RequestId with fn to_json(self) {
  match self {
    Number(value) => Json::number(value.to_double(), repr=value.to_string())
    Str(value) => Json::string(value)
    Null => Json::null()
  }
}

///|
/// Decodes a JSON number, string, or null request identifier.
pub extend RequestId with @json.FromJson::{from_json}

///|
pub impl @json.FromJson for RequestId with fn from_json(value, path) {
  match value {
    Number(raw, ..) if !raw.is_nan() &&
      raw >= -9223372036854775808.0 &&
      raw < 9223372036854775808.0 => {
      let result = raw.to_int64()
      if result.to_double() != raw {
        raise @json.JsonDecodeError((path, "expected an integral request id"))
      }
      Number(result)
    }
    String(value) => Str(value)
    Null => Null
    _ =>
      raise @json.JsonDecodeError(
        (path, "expected an integer, string, or null request id"),
      )
  }
}

///|
/// A JSON-RPC error object.
///
/// ```mbt check
/// test {
///   let error = @jsonrpc.RpcError::invalid_params()
///   assert_eq(error.code, -32602)
///   assert_eq(error.message, "Invalid params")
/// }
/// ```
pub(all) struct RpcError {
  code : Int
  message : String
  data : Json?
} derive(Eq, Debug)

///|
/// Compares all error fields.
pub extend RpcError with Eq::{equal, not_equal}

///|
/// Formats an RPC error for debugging.
pub extend RpcError with @debug.Debug::{to_repr}

///|
/// Creates an RPC error with an optional data value.
pub fn RpcError::new(code~ : Int, message~ : String, data? : Json) -> RpcError {
  { code, message, data, }
}

///|
/// Creates the reserved parse error.
pub fn RpcError::parse_error(message? : String = "Parse error") -> RpcError {
  RpcError::new(code=-32700, message~)
}

///|
/// Creates the reserved invalid request error.
pub fn RpcError::invalid_request(
  message? : String = "Invalid Request",
) -> RpcError {
  RpcError::new(code=-32600, message~)
}

///|
/// Creates the reserved method not found error and records the method as data.
pub fn RpcError::method_not_found(method_name : String) -> RpcError {
  RpcError::new(
    code=-32601,
    message="Method not found",
    data=Json::string(method_name),
  )
}

///|
/// Creates the reserved invalid params error.
pub fn RpcError::invalid_params(
  message? : String = "Invalid params",
) -> RpcError {
  RpcError::new(code=-32602, message~)
}

///|
/// Creates the reserved internal error.
pub fn RpcError::internal_error(
  message? : String = "Internal error",
) -> RpcError {
  RpcError::new(code=-32603, message~)
}

///|
/// Encodes an RPC error object as JSON.
pub extend RpcError with ToJson::{to_json}

///|
pub impl ToJson for RpcError with fn to_json(self) {
  let fields : Map[String, Json] = Map([])
  fields["code"] = self.code.to_json()
  fields["message"] = self.message.to_json()
  if self.data is Some(data) {
    fields["data"] = data
  }
  Json::object(fields)
}

///|
/// Decodes an RPC error object from JSON.
pub extend RpcError with @json.FromJson::{from_json}

///|
pub impl @json.FromJson for RpcError with fn from_json(value, path) {
  guard value is Object(fields) else {
    raise @json.JsonDecodeError((path, "expected an error object"))
  }
  guard fields.get("code") is Some(code_json) else {
    raise @json.JsonDecodeError((path.add_key("code"), "missing code"))
  }
  guard fields.get("message") is Some(message_json) else {
    raise @json.JsonDecodeError((path.add_key("message"), "missing message"))
  }
  guard code_json is Number(raw_code, ..) &&
    !raw_code.is_nan() &&
    raw_code >= -2147483648.0 &&
    raw_code <= 2147483647.0 else {
    raise @json.JsonDecodeError((path.add_key("code"), "expected integer code"))
  }
  let code = raw_code.to_int()
  if code.to_double() != raw_code {
    raise @json.JsonDecodeError((path.add_key("code"), "expected integer code"))
  }
  let message : String = @json.from_json(
    message_json,
    path=path.add_key("message"),
  )
  { code, message, data: fields.get("data"), }
}

///|
/// A decoded JSON-RPC request, notification, response, or failure.
///
/// ```mbt check
/// test {
///   let message = @jsonrpc.Message::Notification(name="ready", params=None)
///   assert_eq(message, @jsonrpc.Message::Notification(name="ready", params=None))
/// }
/// ```
pub(all) enum Message {
  Request(id~ : RequestId, name~ : String, params~ : Json?)
  Notification(name~ : String, params~ : Json?)
  Response(id~ : RequestId, result~ : Json)
  Failure(id~ : RequestId, error~ : RpcError)
} derive(Eq, Debug)

///|
/// Compares all message fields.
pub extend Message with Eq::{equal, not_equal}

///|
/// Formats a message for debugging.
pub extend Message with @debug.Debug::{to_repr}

///|
/// Selects whether the `jsonrpc` member is required on the wire.
pub(all) enum Envelope {
  Strict
  Bare
} derive(Eq, Debug)

///|
/// Compares envelope modes.
pub extend Envelope with Eq::{equal, not_equal}

///|
/// Formats an envelope mode for debugging.
pub extend Envelope with @debug.Debug::{to_repr}

///|
/// Describes why an NDJSON line could not be decoded.
pub(all) suberror DecodeError {
  InvalidJson(String)
  InvalidMessage(String)
  LineTooLong(Int)
} derive(Eq, Debug)

///|
/// Compares decode failures.
pub extend DecodeError with Eq::{equal, not_equal}

///|
/// Formats a decode failure for debugging.
pub extend DecodeError with @debug.Debug::{to_repr}
