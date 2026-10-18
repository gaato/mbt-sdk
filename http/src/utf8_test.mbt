///|
/// `text` with a lone high surrogate before it and a lone low one after.
fn lone_surrogates(text : String) -> String {
  String::from_array([(0xD800).unsafe_to_char()]) +
  text +
  String::from_array([(0xDC00).unsafe_to_char()])
}

///|
test "caller strings with lone surrogates encode with U+FFFD" {
  let text = lone_surrogates("a")
  let request = @http.Request::post("/")
  let rows : Array[(String, Bytes, Bytes)] = [
    ("body_text", request.body_text(text).body, b"\xEF\xBF\xBDa\xEF\xBF\xBD"),
    (
      "json_body",
      request.json_body(Json::string(text)).body,
      b"\"\xEF\xBF\xBDa\xEF\xBF\xBD\"",
    ),
    (
      "form_body",
      request.form_body([("k", text)]).body,
      b"k=%EF%BF%BDa%EF%BF%BD",
    ),
  ]
  for row in rows {
    let (label, body, expected) = row
    assert_eq(body, expected, msg=label)
  }
}

///|
test "Url::parse percent-encodes lone surrogates as U+FFFD" {
  let rows : Array[(String, String, String)] = [
    ("path", "http://h/" + lone_surrogates("p"), "http://h/%EF%BF%BDp%EF%BF%BD"),
    (
      "query",
      "http://h/?" + lone_surrogates("q"),
      "http://h/?%EF%BF%BDq%EF%BF%BD",
    ),
    (
      "fragment",
      "http://h/#" + lone_surrogates("f"),
      "http://h/#%EF%BF%BDf%EF%BF%BD",
    ),
    (
      "userinfo",
      "http://" + lone_surrogates("u") + "@h/",
      "http://%EF%BF%BDu%EF%BF%BD@h/",
    ),
  ]
  for row in rows {
    let (label, text, expected) = row
    let url = @http.Url::parse(text) catch { _ => fail("\{label}: refused") }
    assert_eq(url.to_string(), expected, msg=label)
  }
}

///|
test "encode_utf8 writes each code point and lone surrogate" {
  let unit = (code : Int32) => code.unsafe_to_char()
  let rows : Array[(String, Array[Char], Bytes)] = [
    ("empty", [], b""),
    ("ASCII", ['a', '~'], b"a~"),
    ("two bytes", [unit(0x80), unit(0x7FF)], b"\xC2\x80\xDF\xBF"),
    ("three bytes", [unit(0x800), unit(0xFFFF)], b"\xE0\xA0\x80\xEF\xBF\xBF"),
    ("a pair", [unit(0xD83D), unit(0xDE00)], b"\xF0\x9F\x98\x80"),
    ("the last pair", [unit(0xDBFF), unit(0xDFFF)], b"\xF4\x8F\xBF\xBF"),
    ("high at the end", ['a', unit(0xD800)], b"a\xEF\xBF\xBD"),
    ("low alone", [unit(0xDC00), 'b'], b"\xEF\xBF\xBDb"),
    (
      "high before high",
      [unit(0xD800), unit(0xD83D), unit(0xDE00)],
      b"\xEF\xBF\xBD\xF0\x9F\x98\x80",
    ),
    ("reversed pair", [unit(0xDE00), unit(0xD83D)], b"\xEF\xBF\xBD\xEF\xBF\xBD"),
  ]
  for row in rows {
    let (label, units, expected) = row
    assert_eq(@http.encode_utf8(String::from_array(units)), expected, msg=label)
  }
}

///|
test "encode_utf8 matches @utf8.encode on well-formed text" {
  let rand = @random.Rand::chacha8(seed=Bytes::make(32, b'\x07'))
  for trial in 0..<200 {
    let chars = Array::makei(rand.int(limit=20), _ => {
      let code = match rand.int(limit=4) {
        0 => rand.int(limit=0x80)
        1 => 0x80 + rand.int(limit=0x780)
        2 => 0xE000 + rand.int(limit=0x2000)
        _ => 0x10000 + rand.int(limit=0x100000)
      }
      code.unsafe_to_char()
    })
    let text = String::from_array(chars)
    assert_eq(@http.encode_utf8(text), @utf8.encode(text), msg="trial \{trial}")
  }
}
