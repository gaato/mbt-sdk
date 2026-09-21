///|
/// Decodes a required field, attaching the key to missing or invalid value errors.
pub fn[T : @json.FromJson] field(
  obj : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> T raise @json.JsonDecodeError {
  let path = path.add_key(key)
  match obj.get(key) {
    None => raise @json.JsonDecodeError((path, "missing required field"))
    Some(value) => @json.from_json(value, path~)
  }
}

///|
/// Treats missing fields and null as None; other values must decode as T.
pub fn[T : @json.FromJson] opt_field(
  obj : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> T? raise @json.JsonDecodeError {
  match obj.get(key) {
    None | Some(Null) => None
    Some(value) => Some(@json.from_json(value, path=path.add_key(key)))
  }
}

///|
/// Preserves missing, null, and decoded values as three distinct cases.
pub fn[T : @json.FromJson] presence_field(
  obj : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Presence[T] raise @json.JsonDecodeError {
  match obj.get(key) {
    None => Absent
    Some(Null) => Null
    Some(value) => Value(@json.from_json(value, path=path.add_key(key)))
  }
}

///|
/// Extracts an object's fields or raises at the supplied path.
pub fn expect_object(
  json : Json,
  path : @json.JsonPath,
) -> Map[String, Json] raise @json.JsonDecodeError {
  match json {
    Object(obj) => obj
    _ => raise @json.JsonDecodeError((path, "expected object"))
  }
}

///|
/// Decodes a string enum, preserving unrecognized values through unknown.
pub fn[T] open_string(
  json : Json,
  path : @json.JsonPath,
  known : (String) -> T?,
  unknown : (String) -> T,
) -> T raise @json.JsonDecodeError {
  guard json is String(raw) else {
    raise @json.JsonDecodeError((path, "expected string"))
  }
  match known(raw) {
    Some(value) => value
    None => unknown(raw)
  }
}

///|
/// Decodes an open integer enum, rejecting fractions and values outside Int.
pub fn[T] open_int(
  json : Json,
  path : @json.JsonPath,
  known : (Int) -> T?,
  unknown : (Int) -> T,
) -> T raise @json.JsonDecodeError {
  guard json is Number(raw, ..) && raw >= -2147483648.0 && raw <= 2147483647.0 else {
    raise @json.JsonDecodeError((path, "expected integer in Int range"))
  }
  let value = raw.to_int()
  guard value.to_double() == raw else {
    raise @json.JsonDecodeError(
      (path, "expected integer without fractional part"),
    )
  }
  match known(value) {
    Some(result) => result
    None => unknown(value)
  }
}
