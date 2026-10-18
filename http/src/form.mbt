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
/// Appends one name or value under the urlencoded serializer's rules. The
/// UTF-8 encoding is done here because `@utf8.encode` aborts on a lone
/// surrogate, which the serializer's USVString input has as U+FFFD.
fn form_write(builder : StringBuilder, text : String) -> Unit {
  let units = text.length()
  for i = 0; i < units; {
    let unit = text.code_unit_at(i).to_int()
    let (code_point, width) = if unit >= 0xD800 &&
      unit < 0xDC00 &&
      i + 1 < units &&
      text.code_unit_at(i + 1).to_int() is (0xDC00..<0xE000 as low) {
      (0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00), 2)
    } else if unit >= 0xD800 && unit < 0xE000 {
      (0xFFFD, 1)
    } else {
      (unit, 1)
    }
    if code_point < 0x80 {
      form_byte(builder, code_point)
    } else if code_point < 0x800 {
      form_byte(builder, 0xC0 | (code_point >> 6))
      form_byte(builder, 0x80 | (code_point & 0x3F))
    } else if code_point < 0x10000 {
      form_byte(builder, 0xE0 | (code_point >> 12))
      form_byte(builder, 0x80 | ((code_point >> 6) & 0x3F))
      form_byte(builder, 0x80 | (code_point & 0x3F))
    } else {
      form_byte(builder, 0xF0 | (code_point >> 18))
      form_byte(builder, 0x80 | ((code_point >> 12) & 0x3F))
      form_byte(builder, 0x80 | ((code_point >> 6) & 0x3F))
      form_byte(builder, 0x80 | (code_point & 0x3F))
    }
    continue i + width
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
