///|
/// Parses nonnegative seconds (including decimals) or, given a clock, an
/// HTTP-date in any of RFC 9110's three forms.
/// Results are truncated to milliseconds and saturated at Int max.
///
/// ```mbt check
/// test {
///   assert_eq(@http.parse_retry_after("1.2349"), Some(1234))
/// }
/// ```
pub fn parse_retry_after(value : String, now_unix_ms? : Int64) -> Int32? {
  let value = value.trim().to_owned()
  if decimal_ms(value, 1000) is Some(ms) {
    return Some(ms)
  }
  guard now_unix_ms is Some(now) else { return None }
  guard http_date_ms(value, now) is Some(date) else { return None }
  if date <= now {
    return Some(0)
  }
  // Compare before subtracting: even an Int64-min clock must not overflow.
  if now < date - 2147483647L {
    Some(2147483647)
  } else {
    Some((date - now).to_int())
  }
}

///|
/// Prefers the first retry-after-ms value; falls back to retry-after when that
/// header is absent or unparseable, as the official OpenAI SDKs do.
pub fn retry_after_ms(headers : Headers, now_unix_ms? : Int64) -> Int32? {
  if headers.get("retry-after-ms") is Some(value) &&
    decimal_ms(value.trim().to_owned(), 1) is Some(ms) {
    return Some(ms)
  }
  match headers.get("retry-after") {
    Some(value) => parse_retry_after(value, now_unix_ms?)
    None => None
  }
}

///|
// Validate the whole input even after saturation. No floating-point rounding.
fn decimal_ms(value : String, scale : Int32) -> Int32? {
  let mut whole = 0L
  let mut fraction = 0
  let mut weight = scale
  let mut dot = false
  let mut before = 0
  let mut after = 0
  for c in value {
    if c == '.' && !dot {
      dot = true
    } else if c >= '0' && c <= '9' {
      let digit = c.to_int() - 48
      if dot {
        after += 1
        weight /= 10
        fraction += digit * weight
      } else {
        before += 1
        whole = (whole * 10 + digit.to_int64()).min(2147483647L)
      }
    } else {
      return None
    }
  }
  if before == 0 || (dot && after == 0) {
    return None
  }
  Some(
    (whole * scale.to_int64() + fraction.to_int64()).min(2147483647L).to_int(),
  )
}
