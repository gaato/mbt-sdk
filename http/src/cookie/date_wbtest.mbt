///|
test "cookie dates in the formats servers send parse to Unix milliseconds" {
  let cases : Array[(String, Int64?)] = [
    // RFC 1123, RFC 850 and asctime, the three formats of RFC 7231.
    ("Sun, 06 Nov 1994 08:49:37 GMT", Some(784111777000L)),
    ("Sunday, 06-Nov-94 08:49:37 GMT", Some(784111777000L)),
    ("Sun Nov  6 08:49:37 1994", Some(784111777000L)),
    // RFC 6265 §3.1's example and the Netscape format.
    ("Wed, 09 Jun 2021 10:18:14 GMT", Some(1623233894000L)),
    ("Mon, 10-Dec-2007 17:02:24 GMT", Some(1197306144000L)),
    // Trailing non-digits after a field, and junk tokens, are allowed.
    ("Mon, 10-Dec-2007 17:02:24GMT", Some(1197306144000L)),
    ("Tue, 18 Oct 2011 07:42:42.123 GMT", Some(1318923762000L)),
    ("Tue, 18 Oct 2011 07:42:42 GMT+0700", Some(1318923762000L)),
    ("18 October 2011 07:42:42", Some(1318923762000L)),
    ("10dec2007 17:02:24", None),
    // Fields in any order, months in any case, one-digit fields.
    ("12:34:56 jan 1 2000", Some(946730096000L)),
    ("2000 JAN 01 12:34:56", Some(946730096000L)),
    ("Thu, 1 Jan 1970 0:0:0 GMT", Some(0L)),
    // Two-digit years: 70-99 are 19xx, 00-69 are 20xx.
    ("01 Jan 70 00:00:00", Some(0L)),
    ("01 Jan 69 00:00:00", Some(3124224000000L)),
    // Range checks of §5.1.1 step 5, and dates that do not exist.
    ("01 Jan 1601 00:00:00", Some(-11644473600000L)),
    ("31 Dec 1600 23:59:59", None),
    ("31 Dec 9999 23:59:59", Some(253402300799000L)),
    ("29 Feb 2024 00:00:00", Some(1709164800000L)),
    ("29 Feb 2023 00:00:00", None),
    ("31 Apr 2023 00:00:00", None),
    ("00 Jan 2023 00:00:00", None),
    ("32 Jan 2023 00:00:00", None),
    ("01 Jan 2023 24:00:00", None),
    ("01 Jan 2023 23:60:00", None),
    ("01 Jan 2023 23:59:60", None),
    // A missing field, or one with too many digits, fails.
    ("01 Jan 2023", None),
    ("Jan 2023 00:00:00", None),
    ("01 2023 00:00:00", None),
    ("01 Jan 00:00:00", None),
    ("01 Jan 2023 00:00:000", None),
    ("01 Jan 20231 00:00:00", None),
    ("001 Jan 2023 00:00:00", None),
    ("", None),
    ("not a date", None),
  ]
  for case in cases {
    assert_eq(parse_cookie_date(case.0), case.1, msg=case.0)
  }
}

///|
test "days_from_civil counts days from the Unix epoch" {
  assert_eq(days_from_civil(1970, 1, 1), 0L)
  assert_eq(days_from_civil(1969, 12, 31), -1L)
  assert_eq(days_from_civil(2000, 3, 1), 11017L)
  assert_eq(days_from_civil(1601, 1, 1), -134774L)
}
