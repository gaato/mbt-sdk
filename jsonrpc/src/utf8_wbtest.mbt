///|
test "encode_utf8 writes each code point and lone surrogate" {
  let unit = (code : Int32) => code.unsafe_to_char()
  let rows : Array[(String, Array[Char], Bytes)] = [
    ("ASCII", ['a'], b"a"),
    ("two bytes", [unit(0xE9)], b"\xC3\xA9"),
    ("three bytes", [unit(0x65E5)], b"\xE6\x97\xA5"),
    ("a pair", [unit(0xD83D), unit(0xDE00)], b"\xF0\x9F\x98\x80"),
    ("high at the end", ['a', unit(0xD800)], b"a\xEF\xBF\xBD"),
    ("low alone", [unit(0xDC00), 'b'], b"\xEF\xBF\xBDb"),
  ]
  for row in rows {
    let (label, units, expected) = row
    assert_eq(encode_utf8(String::from_array(units)), expected, msg=label)
  }
}
