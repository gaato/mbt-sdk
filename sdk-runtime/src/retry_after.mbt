///|
/// Parses nonnegative seconds (including decimals) or an IMF-fixdate with a clock.
/// Results are truncated to milliseconds and saturated at Int max.
///
/// ```mbt check
/// test {
///   assert_eq(@runtime.parse_retry_after("1.2349"), Some(1234))
/// }
/// ```
pub fn parse_retry_after(value : String, now_unix_ms? : Int64) -> Int? {
  let value = value.trim().to_owned()
  if decimal_ms(value, 1000) is Some(ms) {
    return Some(ms)
  }
  guard now_unix_ms is Some(now) else { return None }
  guard http_date_ms(value) is Some(date) else { return None }
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
pub fn retry_after_ms(headers : @http.Headers, now_unix_ms? : Int64) -> Int? {
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
fn decimal_ms(value : String, scale : Int) -> Int? {
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

///|
fn date_digits(s : String, start : Int, count : Int) -> Int? {
  let mut n = 0
  for i = start; i < start + count; i = i + 1 {
    guard s[i] >= '0' && s[i] <= '9' else { return None }
    n = n * 10 + s[i].to_int() - 48
  }
  Some(n)
}

///|
fn http_date_ms(s : String) -> Int64? {
  guard s.length() == 29 else { return None }
  guard s[3] == ',' &&
    s[4] == ' ' &&
    s[7] == ' ' &&
    s[11] == ' ' &&
    s[16] == ' ' &&
    s[19] == ':' &&
    s[22] == ':' &&
    s[25] == ' ' else {
    return None
  }
  let weekday = match s {
    ['S', 'u', 'n', ..] => 0
    ['M', 'o', 'n', ..] => 1
    ['T', 'u', 'e', ..] => 2
    ['W', 'e', 'd', ..] => 3
    ['T', 'h', 'u', ..] => 4
    ['F', 'r', 'i', ..] => 5
    ['S', 'a', 't', ..] => 6
    _ => return None
  }
  guard s.has_suffix(" GMT") else { return None }
  let month = match (s[8], s[9], s[10]) {
    ('J', 'a', 'n') => 1
    ('F', 'e', 'b') => 2
    ('M', 'a', 'r') => 3
    ('A', 'p', 'r') => 4
    ('M', 'a', 'y') => 5
    ('J', 'u', 'n') => 6
    ('J', 'u', 'l') => 7
    ('A', 'u', 'g') => 8
    ('S', 'e', 'p') => 9
    ('O', 'c', 't') => 10
    ('N', 'o', 'v') => 11
    ('D', 'e', 'c') => 12
    _ => return None
  }
  guard date_digits(s, 5, 2) is Some(day) else { return None }
  guard date_digits(s, 12, 4) is Some(year) else { return None }
  guard date_digits(s, 17, 2) is Some(hour) else { return None }
  guard date_digits(s, 20, 2) is Some(minute) else { return None }
  guard date_digits(s, 23, 2) is Some(second) else { return None }
  let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let days = match month {
    2 => if leap { 29 } else { 28 }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
  guard year >= 1 &&
    day >= 1 &&
    day <= days &&
    hour < 24 &&
    minute < 60 &&
    second <= 60 else {
    return None
  }
  let days = days_from_civil(year, month, day)
  guard ((days + 4) % 7 + 7) % 7 == weekday else { return None }
  Some(
    ((days.to_int64() * 24 + hour.to_int64()) * 60 + minute.to_int64()) * 60000 +
    second.to_int64() * 1000,
  )
}

///|
// March-based Gregorian eras, with 1970-01-01 as day zero.
fn days_from_civil(year : Int, month : Int, day : Int) -> Int {
  let y = year - (if month <= 2 { 1 } else { 0 })
  let era = y / 400
  let yoe = y - era * 400
  let m = month + (if month > 2 { -3 } else { 9 })
  let doy = (153 * m + 2) / 5 + day - 1
  era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
}
