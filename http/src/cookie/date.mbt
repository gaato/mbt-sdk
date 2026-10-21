///|
/// Parses a cookie-date with the RFC 6265 §5.1.1 algorithm, which accepts the
/// formats servers actually send (RFC 9110 §5.6.7's IMF-fixdate, rfc850-date
/// and asctime-date, and their variants). Returns Unix milliseconds, or `None`
/// when the algorithm fails.
fn parse_cookie_date(text : String) -> Int64? {
  let mut time : (Int32, Int32, Int32)? = None
  let mut day : Int32? = None
  let mut month : Int32? = None
  let mut year : Int32? = None
  for token in date_tokens(text) {
    if time is None && parse_time(token) is Some(hms) {
      time = Some(hms)
    } else if day is None && leading_number(token, 1, 2) is Some(value) {
      day = Some(value)
    } else if month is None && parse_month(token) is Some(value) {
      month = Some(value)
    } else if year is None && leading_number(token, 2, 4) is Some(value) {
      year = Some(value)
    }
  }
  guard time is Some((hour, minute, second)) &&
    day is Some(day) &&
    month is Some(month) &&
    year is Some(year) else {
    return None
  }
  let year = if year >= 70 && year <= 99 {
    year + 1900
  } else if year <= 69 {
    year + 2000
  } else {
    year
  }
  guard day >= 1 &&
    day <= days_in_month(year, month) &&
    year >= 1601 &&
    hour <= 23 &&
    minute <= 59 &&
    second <= 59 else {
    return None
  }
  let days = days_from_civil(year, month, day)
  Some(
    days * 86_400_000L + (hour * 3600 + minute * 60 + second).to_int64() * 1000L,
  )
}

///|
/// Splits on the §5.1.1 delimiters: %x09 / %x20-2F / %x3B-40 / %x5B-60 /
/// %x7B-7E. Everything else, non-ASCII included, belongs to a token.
fn date_tokens(text : String) -> Array[Array[Char]] {
  let tokens = []
  let mut token = []
  for c in text {
    let n = c.to_int()
    let delimiter = n == 0x09 ||
      (n >= 0x20 && n <= 0x2F) ||
      (n >= 0x3B && n <= 0x40) ||
      (n >= 0x5B && n <= 0x60) ||
      (n >= 0x7B && n <= 0x7E)
    if delimiter {
      if !token.is_empty() {
        tokens.push(token)
        token = []
      }
    } else {
      token.push(c)
    }
  }
  if !token.is_empty() {
    tokens.push(token)
  }
  tokens
}

///|
/// Reads `min` to `max` digits from `start`; returns their value and the
/// index after them.
fn digits_at(
  token : Array[Char],
  start : Int32,
  min : Int32,
  max : Int32,
) -> (Int32, Int32)? {
  let mut value = 0
  let mut i = start
  while i < token.length() && i - start < max && token[i].is_ascii_digit() {
    value = value * 10 + (token[i].to_int() - '0'.to_int())
    i += 1
  }
  if i - start >= min {
    Some((value, i))
  } else {
    None
  }
}

///|
/// The `( non-digit *OCTET )` tail: the token ends, or the next character is
/// not a digit.
fn ends_number(token : Array[Char], at : Int32) -> Bool {
  at == token.length() || !token[at].is_ascii_digit()
}

///|
/// `min`*`max`DIGIT ( non-digit *OCTET ): day-of-month (1-2) and year (2-4).
fn leading_number(token : Array[Char], min : Int32, max : Int32) -> Int32? {
  match digits_at(token, 0, min, max) {
    Some((value, end)) if ends_number(token, end) => Some(value)
    _ => None
  }
}

///|
/// hms-time ( non-digit *OCTET ), each time-field 1*2DIGIT.
fn parse_time(token : Array[Char]) -> (Int32, Int32, Int32)? {
  guard digits_at(token, 0, 1, 2) is Some((hour, i)) &&
    i < token.length() &&
    token[i] == ':' &&
    digits_at(token, i + 1, 1, 2) is Some((minute, j)) &&
    j < token.length() &&
    token[j] == ':' &&
    digits_at(token, j + 1, 1, 2) is Some((second, k)) &&
    ends_number(token, k) else {
    return None
  }
  Some((hour, minute, second))
}

///|
/// A token whose first three characters name a month, ignoring ASCII case.
fn parse_month(token : Array[Char]) -> Int32? {
  guard token.length() >= 3 else { return None }
  let prefix = String::from_array(token[:3]).to_lower()
  let months = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov",
    "dec",
  ]
  for i, name in months {
    if name == prefix {
      return Some(i + 1)
    }
  }
  None
}

///|
fn days_in_month(year : Int32, month : Int32) -> Int32 {
  match month {
    2 =>
      if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
        29
      } else {
        28
      }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
}

///|
/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`), for the positive years a cookie-date can name.
fn days_from_civil(year : Int32, month : Int32, day : Int32) -> Int64 {
  let y = if month <= 2 { year - 1 } else { year }
  let era = y / 400
  let yoe = y - era * 400
  let mp = (month + 9) % 12
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era.to_int64() * 146_097L + doe.to_int64() - 719_468L
}
