// go.lsp.dev/jsonrpc2's conformance vectors (see NOTICE), rewritten as
// MoonBit: what a strict decode of each wire message must give. The
// examples of the JSON-RPC 2.0 specification are in
// jsonrpc/src/message_test.mbt.

///|
/// What a vector expects a strict decode to give.
priv enum Expect {
  Call(String, String)
  Notify(String, String)
  Result(String)
  Error(Int32)
  Invalid
}

///|
/// `(name, wire, expected)`. A params or result of `""` means absent.
let vectors : Array[(String, String, Expect)] = [
  (
    "call with object params",
    (
      #|{"jsonrpc":"2.0","method":"sum","params":{"a":1,"b":2},"id":1}
    ),
    Call("sum", "{\"a\":1,\"b\":2}"),
  ),
  (
    "call with array params",
    (
      #|{"jsonrpc":"2.0","method":"subtract","params":[42,23],"id":2}
    ),
    Call("subtract", "[42,23]"),
  ),
  (
    "call with string id",
    (
      #|{"jsonrpc":"2.0","method":"ping","id":"abc"}
    ),
    Call("ping", ""),
  ),
  (
    "notification without params",
    (
      #|{"jsonrpc":"2.0","method":"update"}
    ),
    Notify("update", ""),
  ),
  (
    "notification with params",
    (
      #|{"jsonrpc":"2.0","method":"notify","params":[1,2,3]}
    ),
    Notify("notify", "[1,2,3]"),
  ),
  (
    "notification with explicit null id",
    (
      #|{"jsonrpc":"2.0","method":"notify","id":null}
    ),
    Notify("notify", ""),
  ),
  (
    "success response with result",
    (
      #|{"jsonrpc":"2.0","result":19,"id":3}
    ),
    Result("19"),
  ),
  (
    "success response with result null",
    (
      #|{"jsonrpc":"2.0","result":null,"id":4}
    ),
    Result("null"),
  ),
  (
    "error response with null id",
    (
      #|{"jsonrpc":"2.0","error":{"code":-32700,"message":"parse error"},"id":null}
    ),
    Error(-32700),
  ),
  (
    "error response with data",
    (
      #|{"jsonrpc":"2.0","error":{"code":-32602,"message":"invalid params","data":{"detail":"x"}},"id":5}
    ),
    Error(-32602),
  ),
  (
    "call with escaped method name",
    (
      #|{"jsonrpc":"2.0","method":"a\/b\n","id":6}
    ),
    Call("a/b\n", ""),
  ),
  (
    "call with whitespace around tokens",
    (
      #|{ "jsonrpc" : "2.0" , "method" : "m" , "id" : 7 }
    ),
    Call("m", ""),
  ),
  (
    "call with nested params and strings containing braces",
    (
      #|{"jsonrpc":"2.0","method":"m","params":{"s":"}{[]","n":[{"k":"v"}]},"id":8}
    ),
    Call("m", "{\"s\":\"}{[]\",\"n\":[{\"k\":\"v\"}]}"),
  ),
  (
    "call with params null treated as absent",
    (
      #|{"jsonrpc":"2.0","method":"m","params":null,"id":9}
    ),
    Call("m", ""),
  ),
  (
    "call with negative numeric id",
    (
      #|{"jsonrpc":"2.0","method":"m","id":-15}
    ),
    Call("m", ""),
  ),
  ("empty input", "", Invalid),
  ("not an object", "42", Invalid),
  (
    "truncated object",
    (
      #|{"jsonrpc":"2.0","method":"m"
    ),
    Invalid,
  ),
  (
    "response without result or error",
    (
      #|{"jsonrpc":"2.0","id":1}
    ),
    Invalid,
  ),
  (
    "method with result is mixed",
    (
      #|{"jsonrpc":"2.0","method":"m","result":1,"id":1}
    ),
    Invalid,
  ),
  (
    "trailing garbage",
    (
      #|{"jsonrpc":"2.0","method":"m","id":1}x
    ),
    Invalid,
  ),
  (
    "unterminated string",
    (
      #|{"jsonrpc":"2.0","method":"m
    ),
    Invalid,
  ),
  (
    "missing jsonrpc version",
    (
      #|{"method":"m","id":1}
    ),
    Invalid,
  ),
  (
    "wrong jsonrpc version",
    (
      #|{"jsonrpc":"1.0","method":"m","id":1}
    ),
    Invalid,
  ),
  (
    "jsonrpc version as number",
    (
      #|{"jsonrpc":2.0,"method":"m","id":1}
    ),
    Invalid,
  ),
  (
    "jsonrpc version null",
    (
      #|{"jsonrpc":null,"method":"m","id":1}
    ),
    Invalid,
  ),
  (
    "missing version on response",
    (
      #|{"result":1,"id":1}
    ),
    Invalid,
  ),
  (
    "response with both result and error",
    (
      #|{"jsonrpc":"2.0","result":1,"error":{"code":-32000,"message":"boom"},"id":1}
    ),
    Invalid,
  ),
]

///|
/// Vectors whose expectation this decoder deliberately does not share.
let differences : Map[String, String] = {
  // JSON-RPC 2.0 §4.1: a notification is a request without an `id` member.
  // `"id":null` is a request with a null id (Request(Null)), discouraged by
  // §4 but not a notification.
  "notification with explicit null id": "a null id is a request",
  // §4.2 asks for a structured params value; a null one is kept as given
  // (Some(Null)) rather than read as absent.
  "call with params null treated as absent": "null params kept",
}

///|
fn params_of(text : String) -> Json? raise {
  if text.is_empty() {
    None
  } else {
    Some(@json.parse(text))
  }
}

///|
test "a strict decode classifies go.lsp.dev's vectors" {
  let skipped = []
  for row in vectors {
    let (name, wire, expected) = row
    if differences.get(name) is Some(reason) {
      skipped.push(reason)
      continue
    }
    let wire_bytes = @utf8.encode(wire)
    let decoded = @jsonrpc.decode_line(wire_bytes, envelope=Strict) catch {
      _ => {
        assert_true(expected is Invalid, msg="\{name}: refused")
        continue
      }
    }
    let matches = match (expected, decoded) {
      (Call(wanted, params), Request(name~, params=actual, ..)) =>
        name == wanted && actual == params_of(params)
      (Notify(wanted, params), Notification(name~, params=actual)) =>
        name == wanted && actual == params_of(params)
      (Result(result), Response(result=actual, ..)) =>
        actual == @json.parse(result)
      (Error(code), Failure(error~, ..)) => error.code == code
      _ => false
    }
    assert_true(matches, msg="\{name}: \{Repr(decoded)}")
  }
  debug_inspect(
    skipped,
    content=(
      #|["a null id is a request", "null params kept"]
    ),
  )
}
