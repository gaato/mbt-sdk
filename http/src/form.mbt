///|
/// Serializes name/value pairs, in order, as an
/// `application/x-www-form-urlencoded` body with the WHATWG URL Standard's
/// urlencoded serializer, as browsers and `URLSearchParams` do: a space
/// becomes `+`, and every UTF-8 byte other than an ASCII alphanumeric or one
/// of `*-._` is percent-encoded in uppercase hex. This differs from
/// `percent_encode`, which keeps `~`, encodes `*` and writes a space as
/// `%20`. A lone surrogate is encoded as U+FFFD.
///
/// ```mbt check
/// test {
///   assert_eq(
///     @http.form_urlencode([("q", "a b&c"), ("lang", "日本")]),
///     "q=a+b%26c&lang=%E6%97%A5%E6%9C%AC",
///   )
/// }
/// ```
pub fn form_urlencode(pairs : ArrayView[(String, String)]) -> String {
  let builder = StringBuilder()
  for i, pair in pairs {
    if i > 0 {
      builder.write_char('&')
    }
    let (name, value) = pair
    form_write(builder, name)
    builder.write_char('=')
    form_write(builder, value)
  }
  builder.to_string()
}

///|
/// Encodes `pairs` with `form_urlencode` as the body and supplies
/// `application/x-www-form-urlencoded` only if content-type is absent.
pub fn Request::form_body(
  self : Request,
  pairs : ArrayView[(String, String)],
) -> Request {
  let request = self.body_text(form_urlencode(pairs))
  if !request.headers.contains("content-type") {
    request.headers.set("content-type", "application/x-www-form-urlencoded")
  }
  request
}

///|
/// Appends one name or value under the urlencoded serializer's rules.
fn form_write(builder : StringBuilder, text : String) -> Unit {
  for byte in encode_utf8(text) {
    form_byte(builder, byte.to_int())
  }
}

///|
/// Appends one UTF-8 byte: kept, `+` for a space, or percent-encoded.
fn form_byte(builder : StringBuilder, byte : Int32) -> Unit {
  match byte {
    0x20 => builder.write_char('+')
    '0'..<='9' | 'A'..<='Z' | 'a'..<='z' | '*' | '-' | '.' | '_' =>
      builder.write_char(byte.unsafe_to_char())
    _ => {
      builder.write_char('%')
      builder.write_char(form_hex(byte >> 4))
      builder.write_char(form_hex(byte & 15))
    }
  }
}

///|
/// The uppercase hex digit for a nibble.
fn form_hex(nibble : Int32) -> Char {
  if nibble < 10 {
    ('0'.to_int() + nibble).unsafe_to_char()
  } else {
    ('A'.to_int() + nibble - 10).unsafe_to_char()
  }
}
