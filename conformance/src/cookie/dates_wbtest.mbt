///|
/// Unix milliseconds of an IMF-fixdate, which is how the tests write the
/// expected dates.
fn imf_ms(text : String) -> Int64 raise {
  let months = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
    "Dec",
  ]
  guard text.length() == 29 &&
    months.search(text[8:11].to_owned()) is Some(index) else {
    fail("not an IMF-fixdate: \{text}")
  }
  let number = (start : Int32, end : Int32) => {
    @string.parse_int(text[start:end].to_owned())
  }
  let year = number(12, 16)
  let month = index + 1
  // Days from 1970-01-01, on March-based eras.
  let y = year - (if month <= 2 { 1 } else { 0 })
  let era = y / 400
  let yoe = y - era * 400
  let m = month + (if month > 2 { -3 } else { 9 })
  let doy = (153 * m + 2) / 5 + number(5, 7) - 1
  let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
  (
    (days.to_int64() * 24L + number(17, 19).to_int64()) * 60L +
    number(20, 22).to_int64()
  ) *
  60000L +
  number(23, 25).to_int64() * 1000L
}

///|
/// The expiry the jar gives `Expires=<date>`, with its clock a day before
/// `expected`, so the 400-day cap and expiry play no part.
fn stored_expiry(date : String, expected : Int64?) -> Int64? {
  let now = match expected {
    Some(ms) => ms - 86_400_000L
    None => NOW
  }
  let jar = @cookie.CookieJar::new(@mock.FakeClock::new(start_unix_ms=now))
  jar.store(
    @http.Headers::from_array([("Set-Cookie", "a=b; Expires=" + date)]),
    "http://home.example.org/",
  )
  jar.iter().next().unwrap().expires_ms
}

///|
test "cookie dates parse as the http-state date tests expect" {
  for
    name_and_rows in [
      ("examples", date_examples),
      ("bsd-examples", date_bsd_examples),
    ] {
    let (name, rows) = name_and_rows
    guard @json.parse(rows) is Array(rows) else { fail("expected rows") }
    for row in rows {
      guard row is { "test": String(date), "expected": expected, .. } else {
        fail("malformed row \{row.stringify()}")
      }
      let expected = match expected {
        String(text) => Some(imf_ms(text))
        _ => None
      }
      assert_eq(stored_expiry(date, expected), expected, msg="\{name} \{date}")
    }
  }
}
