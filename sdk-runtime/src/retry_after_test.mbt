///|
test "decimal seconds validate completely and saturate without rounding" {
  for
    (value, expected) in [
      ("0", Some(0)),
      ("12", Some(12000)),
      ("1.5", Some(1500)),
      ("1.2349", Some(1234)),
      ("0.0009999", Some(0)),
      ("0001.02", Some(1020)),
      (" \t1.25\r\n", Some(1250)),
      ("2147483.647", Some(2147483647)),
      ("2147483.648", Some(2147483647)),
      ("99999999999999999999999999999.99999", Some(2147483647)),
      ("-1", None),
      ("-0.5", None),
      ("+1", None),
      ("1e3", None),
      ("", None),
      (" \t", None),
      (".5", None),
      ("1.", None),
      ("1.2.3", None),
      ("1 2", None),
      ("NaN", None),
      ("Infinity", None),
      ("garbage", None),
      ("999999999999999999999999x", None),
      ("１", None),
    ] {
    assert_eq(@runtime.parse_retry_after(value), expected, msg=value)
  }
}

///|
test "header precedence units duplicates and ASCII case" {
  let headers = @http.Headers::new()
  assert_eq(@runtime.retry_after_ms(headers), None)
  headers.set("ReTrY-AfTeR", "1.25")
  assert_eq(@runtime.retry_after_ms(headers), Some(1250))
  for
    (value, expected) in [
      ("12", Some(12)),
      (" 12.9999\t", Some(12)),
      ("0.999", Some(0)),
      ("2147483647", Some(2147483647)),
      ("999999999999999999999.5", Some(2147483647)),
      ("-1", Some(1250)), // falls back to retry-after: 1.25
      ("garbage", Some(1250)), // falls back to retry-after: 1.25
      ("", Some(1250)), // falls back to retry-after: 1.25
      (".5", Some(1250)), // falls back to retry-after: 1.25
      ("1.", Some(1250)), // falls back to retry-after: 1.25
      ("1e3", Some(1250)), // falls back to retry-after: 1.25
      ("99999999999999x", Some(1250)), // falls back to retry-after: 1.25
    ] {
    headers.set("RETRY-after-MS", value)
    assert_eq(@runtime.retry_after_ms(headers), expected, msg=value)
  }
  headers.set("retry-after-ms", "8")
  headers.append("Retry-After-Ms", "99")
  assert_eq(@runtime.retry_after_ms(headers), Some(8))
  headers.remove("retry-after")
  headers.set("retry-after-ms", "garbage")
  assert_eq(@runtime.retry_after_ms(headers), None)
  headers.remove("retry-after-ms")
  headers.set("retry-after", "Thu, 01 Jan 1970 00:00:01 GMT")
  assert_eq(@runtime.retry_after_ms(headers), None)
  assert_eq(@runtime.retry_after_ms(headers, now_unix_ms=0L), Some(1000))
}

///|
test "IMF fixdate epoch clock extremes and truncation independent of local timezone" {
  let date = "Sun, 06 Nov 1994 08:49:37 GMT"
  assert_eq(@runtime.parse_retry_after(date), None)
  assert_eq(
    @runtime.parse_retry_after(date, now_unix_ms=784111776123L),
    Some(877),
  )
  assert_eq(
    @runtime.parse_retry_after(date, now_unix_ms=784111777000L),
    Some(0),
  )
  assert_eq(
    @runtime.parse_retry_after(date, now_unix_ms=784111778000L),
    Some(0),
  )
  assert_eq(@runtime.parse_retry_after(date, now_unix_ms=0L), Some(2147483647))
  assert_eq(
    @runtime.parse_retry_after(date, now_unix_ms=-9223372036854775808L),
    Some(2147483647),
  )
  assert_eq(
    @runtime.parse_retry_after(date, now_unix_ms=9223372036854775807L),
    Some(0),
  )
  assert_eq(
    @runtime.parse_retry_after(
      " \tThu, 01 Jan 1970 00:00:01 GMT\r\n",
      now_unix_ms=0L,
    ),
    Some(1000),
  )
  assert_eq(
    @runtime.parse_retry_after(
      "Wed, 31 Dec 1969 23:59:59 GMT",
      now_unix_ms=-2000L,
    ),
    Some(1000),
  )
  assert_eq(
    @runtime.parse_retry_after(
      "Thu, 01 Jan 1970 00:00:00 GMT",
      now_unix_ms=-2147483647L,
    ),
    Some(2147483647),
  )
}

///|
test "Gregorian leap years and month boundaries" {
  // Known UTC epoch milliseconds, exercising March-based year/era boundaries.
  for
    (date, epoch) in [
      ("Mon, 01 Jan 0001 00:00:00 GMT", -62135596800000L),
      ("Thu, 01 Mar 1900 00:00:00 GMT", -2203891200000L),
      ("Tue, 29 Feb 2000 00:00:00 GMT", 951782400000L),
      ("Wed, 01 Mar 2000 00:00:00 GMT", 951868800000L),
      ("Thu, 29 Feb 2024 00:00:00 GMT", 1709164800000L),
      ("Fri, 01 Mar 2024 00:00:00 GMT", 1709251200000L),
      ("Mon, 01 Apr 2024 00:00:00 GMT", 1711929600000L),
      ("Wed, 01 May 2024 00:00:00 GMT", 1714521600000L),
      ("Sat, 01 Jun 2024 00:00:00 GMT", 1717200000000L),
      ("Mon, 01 Jul 2024 00:00:00 GMT", 1719792000000L),
      ("Thu, 01 Aug 2024 00:00:00 GMT", 1722470400000L),
      ("Sun, 01 Sep 2024 00:00:00 GMT", 1725148800000L),
      ("Tue, 01 Oct 2024 00:00:00 GMT", 1727740800000L),
      ("Fri, 01 Nov 2024 00:00:00 GMT", 1730419200000L),
      ("Sun, 01 Dec 2024 00:00:00 GMT", 1733011200000L),
      ("Wed, 01 Jan 2025 00:00:00 GMT", 1735689600000L),
      ("Mon, 01 Mar 2100 00:00:00 GMT", 4107542400000L),
    ] {
    assert_eq(
      @runtime.parse_retry_after(date, now_unix_ms=epoch - 1000L),
      Some(1000),
      msg=date,
    )
    assert_eq(
      @runtime.parse_retry_after(date, now_unix_ms=epoch + 1L),
      Some(0),
      msg=date,
    )
  }
  // Leap-second syntax is accepted as the following Unix second.
  assert_eq(
    @runtime.parse_retry_after(
      "Sat, 31 Dec 2016 23:59:60 GMT",
      now_unix_ms=1483228799000L,
    ),
    Some(1000),
  )
}

///|
test "invalid dates obsolete formats and inconsistent weekday are rejected" {
  for
    date in [
      "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994", "Sun, 06 Nov 1994 08:49:37 UTC",
      "sun, 06 Nov 1994 08:49:37 GMT", "Mon, 06 Nov 1994 08:49:37 GMT", "Sun, 06 Xxx 1994 08:49:37 GMT",
      "Sun, 06 nov 1994 08:49:37 GMT", "Thu, 29 Feb 1900 00:00:00 GMT", "Wed, 29 Feb 2023 00:00:00 GMT",
      "Mon, 31 Apr 2024 00:00:00 GMT", "Thu, 00 Feb 2024 00:00:00 GMT", "Thu, 32 Feb 2024 00:00:00 GMT",
      "Thu, 29 Feb 2024 24:00:00 GMT", "Thu, 29 Feb 2024 00:60:00 GMT", "Thu, 29 Feb 2024 00:00:61 GMT",
      "Thu, 29 Feb 0000 00:00:00 GMT", "Thu, 2x Feb 2024 00:00:00 GMT", "Thu, 29 Feb 2024 00-00:00 GMT",
      "Thu, 29 Feb 2024 00:00:00 GMT extra", "🌙🌙🌙🌙🌙🌙🌙🌙🌙🌙🌙🌙🌙abc",
    ] {
    assert_eq(@runtime.parse_retry_after(date, now_unix_ms=0L), None, msg=date)
  }
}
