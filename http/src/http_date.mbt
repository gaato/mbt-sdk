///|
/// An HTTP-date (RFC 9110 §5.6.7) in Unix milliseconds: IMF-fixdate, or one of
/// the two obsolete forms a recipient must also accept, rfc850-date and
/// asctime-date. HTTP-date is case-sensitive. `now_unix_ms` places
/// rfc850-date's two-digit year.
fn http_date_ms(s : String, now_unix_ms : Int64) -> Int64? {
  match imf_fixdate(s) {
    Some(ms) => Some(ms)
    None =>
      match rfc850_date(s, now_unix_ms) {
        Some(ms) => Some(ms)
        None => asctime_date(s)
      }
  }
}

///|
/// `Sun, 06 Nov 1994 08:49:37 GMT`
fn imf_fixdate(s : String) -> Int64? {
  guard s.length() == 29 &&
    s[3] == ',' &&
    s[4] == ' ' &&
    s[7] == ' ' &&
    s[11] == ' ' &&
    s[16] == ' ' &&
    s.has_suffix(" GMT") else {
    return None
  }
  guard short_day_name(s, 0) is Some(weekday) else { return None }
  guard date_digits(s, 5, 2) is Some(day) else { return None }
  guard month_name(s, 8) is Some(month) else { return None }
  guard date_digits(s, 12, 4) is Some(year) else { return None }
  guard time_of_day(s, 17) is Some(time) else { return None }
  date_ms(weekday, year, month, day, time)
}

///|
/// `Sunday, 06-Nov-94 08:49:37 GMT`. A two-digit year that would put the date
/// more than 50 years after `now_unix_ms` is taken from the century before.
fn rfc850_date(s : String, now_unix_ms : Int64) -> Int64? {
  guard s.find(", ") is Some(comma) else { return None }
  guard long_day_name(s[:comma]) is Some(weekday) else { return None }
  let at = comma + 2
  guard s.length() == at + 22 &&
    s[at + 2] == '-' &&
    s[at + 6] == '-' &&
    s[at + 9] == ' ' &&
    s.has_suffix(" GMT") else {
    return None
  }
  guard date_digits(s, at, 2) is Some(day) else { return None }
  guard month_name(s, at + 3) is Some(month) else { return None }
  guard date_digits(s, at + 7, 2) is Some(two_digits) else { return None }
  guard time_of_day(s, at + 10) is Some(time) else { return None }
  let now_year = year_of(now_unix_ms)
  let year = now_year - now_year % 100 + two_digits
  let year = if year > now_year + 50 { year - 100 } else { year }
  date_ms(weekday, year, month, day, time)
}

///|
/// `Sun Nov  6 08:49:37 1994`: the day is two digits, or a space and one.
fn asctime_date(s : String) -> Int64? {
  guard s.length() == 24 &&
    s[3] == ' ' &&
    s[7] == ' ' &&
    s[10] == ' ' &&
    s[19] == ' ' else {
    return None
  }
  guard short_day_name(s, 0) is Some(weekday) else { return None }
  guard month_name(s, 4) is Some(month) else { return None }
  let day = if s[8] == ' ' {
    date_digits(s, 9, 1)
  } else {
    date_digits(s, 8, 2)
  }
  guard day is Some(day) else { return None }
  guard time_of_day(s, 11) is Some(time) else { return None }
  guard date_digits(s, 20, 4) is Some(year) else { return None }
  date_ms(weekday, year, month, day, time)
}

///|
fn date_digits(s : String, start : Int32, count : Int32) -> Int32? {
  let mut n = 0
  for i = start; i < start + count; i = i + 1 {
    guard s[i] >= '0' && s[i] <= '9' else { return None }
    n = n * 10 + s[i].to_int() - 48
  }
  Some(n)
}

///|
/// `HH:MM:SS` at `at`, unvalidated.
fn time_of_day(s : String, at : Int32) -> (Int32, Int32, Int32)? {
  guard s[at + 2] == ':' && s[at + 5] == ':' else { return None }
  guard date_digits(s, at, 2) is Some(hour) else { return None }
  guard date_digits(s, at + 3, 2) is Some(minute) else { return None }
  guard date_digits(s, at + 6, 2) is Some(second) else { return None }
  Some((hour, minute, second))
}

///|
/// `day-name` at `at`, Sunday as 0.
fn short_day_name(s : String, at : Int32) -> Int32? {
  match (s[at], s[at + 1], s[at + 2]) {
    ('S', 'u', 'n') => Some(0)
    ('M', 'o', 'n') => Some(1)
    ('T', 'u', 'e') => Some(2)
    ('W', 'e', 'd') => Some(3)
    ('T', 'h', 'u') => Some(4)
    ('F', 'r', 'i') => Some(5)
    ('S', 'a', 't') => Some(6)
    _ => None
  }
}

///|
/// `day-name-l`, Sunday as 0.
fn long_day_name(name : StringView) -> Int32? {
  match name {
    "Sunday" => Some(0)
    "Monday" => Some(1)
    "Tuesday" => Some(2)
    "Wednesday" => Some(3)
    "Thursday" => Some(4)
    "Friday" => Some(5)
    "Saturday" => Some(6)
    _ => None
  }
}

///|
fn month_name(s : String, at : Int32) -> Int32? {
  match (s[at], s[at + 1], s[at + 2]) {
    ('J', 'a', 'n') => Some(1)
    ('F', 'e', 'b') => Some(2)
    ('M', 'a', 'r') => Some(3)
    ('A', 'p', 'r') => Some(4)
    ('M', 'a', 'y') => Some(5)
    ('J', 'u', 'n') => Some(6)
    ('J', 'u', 'l') => Some(7)
    ('A', 'u', 'g') => Some(8)
    ('S', 'e', 'p') => Some(9)
    ('O', 'c', 't') => Some(10)
    ('N', 'o', 'v') => Some(11)
    ('D', 'e', 'c') => Some(12)
    _ => None
  }
}

///|
/// Validates the fields, the weekday included, and converts them to Unix
/// milliseconds. Second 60 is accepted and lands on the next second.
fn date_ms(
  weekday : Int32,
  year : Int32,
  month : Int32,
  day : Int32,
  time : (Int32, Int32, Int32),
) -> Int64? {
  let (hour, minute, second) = time
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
/// The Gregorian year of a Unix time, clamped to 0–99999 so that an extreme
/// clock cannot overflow the year arithmetic.
fn year_of(unix_ms : Int64) -> Int32 {
  let day = if unix_ms >= 0L {
    unix_ms / 86400000L
  } else {
    (unix_ms + 1L) / 86400000L - 1L
  }
  // The inverse of `days_from_civil`, on March-based eras.
  let z = day + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let march_month = (5L * doy + 2L) / 153L
  let year = yoe + era * 400L + (if march_month >= 10L { 1L } else { 0L })
  year.max(0L).min(99999L).to_int()
}

///|
// March-based Gregorian eras, with 1970-01-01 as day zero.
fn days_from_civil(year : Int32, month : Int32, day : Int32) -> Int32 {
  let y = year - (if month <= 2 { 1 } else { 0 })
  let era = y / 400
  let yoe = y - era * 400
  let m = month + (if month > 2 { -3 } else { 9 })
  let doy = (153 * m + 2) / 5 + day - 1
  era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
}
