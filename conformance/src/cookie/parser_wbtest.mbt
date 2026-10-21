///|
/// 2020-09-13T12:26:40Z: after the tests' past expiry dates (2007) and before
/// their future ones (9999).
const NOW : Int64 = 1_600_000_000_000L

///|
fn string_field(fields : Map[String, Json], name : String) -> String? {
  match fields.get(name) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
/// The `Cookie` header the test expects, or `None` for no cookies.
fn expected_header(sent : Array[Json]) -> String? raise {
  let pairs = sent.map(cookie => {
    guard cookie is { "name": String(name), "value": String(value), .. } else {
      fail("malformed cookie \{cookie.stringify()}")
    }
    if name.is_empty() {
      value
    } else {
      name + "=" + value
    }
  })
  if pairs.is_empty() {
    None
  } else {
    Some(pairs.join("; "))
  }
}

///|
/// Runs one test as tough-cookie's harness does: every `received` line is
/// stored from `http://home.example.org/cookie-parser?<test>`, then the
/// header for `sent-to` (resolved against `http://home.example.org`) or
/// `http://home.example.org/cookie-parser-result?<test>` is built.
fn run_parser_test(fields : Map[String, Json]) -> (String?, String?) raise {
  guard string_field(fields, "test") is Some(id) &&
    fields.get("received") is Some(Array(received)) &&
    fields.get("sent") is Some(Array(sent)) else {
    fail("malformed test")
  }
  let jar = @cookie.CookieJar::new(@mock.FakeClock::new(start_unix_ms=NOW))
  let from = "http://home.example.org/cookie-parser?\{id}"
  let lines = received.map(line => {
    guard line is String(text) else { fail("malformed line") }
    ("Set-Cookie", text)
  })
  jar.store(@http.Headers::from_array(lines), from)
  let to = match string_field(fields, "sent-to") {
    Some(target) =>
      @http.Url::parse("http://home.example.org")
      .resolve(@http.Url::parse(target))
      .to_string()
    None => "http://home.example.org/cookie-parser-result?\{id}"
  }
  (jar.header_for(to), expected_header(sent))
}

///|
/// Why a test does not apply to a jar that follows RFC 6265bis-22, or
/// `None` when it does. The http-state tests were written for RFC 6265.
fn not_applicable(id : String, received : Array[Json]) -> String? {
  if id.has_prefix("DISABLED_") {
    return Some("disabled upstream")
  }
  let nameless = received
    .iter()
    .any(line => {
      guard line is String(text) else { return false }
      let pair = text.split(";").next().unwrap_or("")
      match pair.split_once("=") {
        None => true
        Some((name, _)) => name.trim(chars=" \t").is_empty()
      }
    })
  if nameless {
    // §5.6 step 3: a pair without `=`, or with an empty name, is a cookie
    // without a name; RFC 6265 ignored it.
    return Some("cookie without a name")
  }
  if id == "OPTIONAL_DOMAIN0042" {
    // §5.7 step 7: the last Domain counts even when empty, which makes the
    // cookie host-only; RFC 6265 kept the earlier one.
    return Some("empty last Domain")
  }
  None
}

///|
test "the jar sends what the http-state tests expect" {
  guard @json.parse(parser_tests) is Array(tests) else {
    fail("expected tests")
  }
  let skipped : Map[String, Int32] = Map([])
  let mut checked = 0
  for test_case in tests {
    guard test_case is Object(fields) &&
      string_field(fields, "test") is Some(id) &&
      fields.get("received") is Some(Array(received)) else {
      fail("malformed test \{test_case.stringify()}")
    }
    if not_applicable(id, received) is Some(reason) {
      skipped[reason] = skipped.get(reason).unwrap_or(0) + 1
      continue
    }
    checked += 1
    let (actual, expected) = run_parser_test(fields)
    assert_eq(actual, expected, msg=id)
  }
  debug_inspect(
    (checked, skipped.to_array()),
    content=(
      #|(
      #|  189,
      #|  [
      #|    ("cookie without a name", 28),
      #|    ("disabled upstream", 4),
      #|    ("empty last Domain", 1),
      #|  ],
      #|)
    ),
  )
}
