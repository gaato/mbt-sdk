///|
/// Encodes `text` as UTF-8, writing each lone surrogate as U+FFFD, as the
/// WHATWG UTF-8 encoder does; `@utf8.encode` aborts on one. A copy of
/// `@http.encode_utf8`, since this module depends on nothing but core.
fn encode_utf8(text : String) -> Bytes {
  let buffer = Buffer(size_hint=text.length())
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
      buffer.write_byte(code_point.to_byte())
    } else if code_point < 0x800 {
      buffer.write_byte((0xC0 | (code_point >> 6)).to_byte())
      buffer.write_byte((0x80 | (code_point & 0x3F)).to_byte())
    } else if code_point < 0x10000 {
      buffer.write_byte((0xE0 | (code_point >> 12)).to_byte())
      buffer.write_byte((0x80 | ((code_point >> 6) & 0x3F)).to_byte())
      buffer.write_byte((0x80 | (code_point & 0x3F)).to_byte())
    } else {
      buffer.write_byte((0xF0 | (code_point >> 18)).to_byte())
      buffer.write_byte((0x80 | ((code_point >> 12) & 0x3F)).to_byte())
      buffer.write_byte((0x80 | ((code_point >> 6) & 0x3F)).to_byte())
      buffer.write_byte((0x80 | (code_point & 0x3F)).to_byte())
    }
    continue i + width
  }
  buffer.to_bytes()
}
