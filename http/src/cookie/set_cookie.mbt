///|
/// The most a cookie's name and value may take together, in UTF-8 bytes
/// (RFC 6265bis-22 §5.6 step 5); a longer one is ignored whole. Attributes
/// are bounded one by one, by `max_attribute_bytes`.
let max_cookie_bytes : Int32 = 4096

///|
/// The most one attribute value may take, in UTF-8 bytes (RFC 6265bis-22
/// §5.6); a longer attribute is ignored.
let max_attribute_bytes : Int32 = 1024

///|
/// A `Set-Cookie` value parsed by RFC 6265bis-22 §5.6, before the storage
/// model decides what it means for the request.
priv struct SetCookie {
  /// Empty for a cookie without `=` in its name-value pair.
  name : String
  value : String
  /// The last valid `Expires`, in Unix milliseconds.
  expires_ms : Int64?
  /// The last valid `Max-Age`, in seconds; it overrides `Expires`.
  max_age : Int64?
  /// The last `Domain`, lowercased, one leading dot removed; `None` when
  /// there is none or the last one is empty (§5.7 step 10: host-only).
  domain : String?
  /// The last `Path` value, which may still need the default path.
  path : String?
  secure : Bool
  http_only : Bool
  same_site : SameSite?
}

///|
/// Parses a `Set-Cookie` value as RFC 6265bis-22 §5.6 does, or returns
/// `None` when it is ignored: a control character other than HTAB anywhere,
/// a name and value longer than `max_cookie_bytes` together, or, by §5.7
/// step 2, an empty name and an empty value. A pair without `=` is a value
/// with an empty name. Unknown and malformed attributes are skipped.
fn parse_set_cookie(text : String) -> SetCookie? {
  guard !has_control(text) else { return None }
  let (pair, attributes) = match text.split_once(";") {
    Some((pair, attributes)) => (pair, attributes)
    None => (text[:], ""[:])
  }
  let (name, value) = match pair.split_once("=") {
    Some((name, value)) => (trim_wsp(name), trim_wsp(value))
    None => ("", trim_wsp(pair))
  }
  guard !(name.is_empty() && value.is_empty()) &&
    utf8_length(name) + utf8_length(value) <= max_cookie_bytes else {
    return None
  }
  let mut expires_ms = None
  let mut max_age = None
  let mut domain = None
  let mut path = None
  let mut secure = false
  let mut http_only = false
  let mut same_site = None
  for av in attributes.split(";") {
    let (key, value) = match av.split_once("=") {
      Some((key, value)) => (trim_wsp(key), trim_wsp(value))
      None => (trim_wsp(av), "")
    }
    if utf8_length(value) > max_attribute_bytes {
      continue
    }
    match key.to_lower() {
      "expires" =>
        if parse_cookie_date(value) is Some(ms) {
          expires_ms = Some(ms)
        }
      "max-age" =>
        if parse_max_age(value) is Some(seconds) {
          max_age = Some(seconds)
        }
      "domain" => {
        let value = value.strip_prefix(".").unwrap_or(value[:]).to_owned()
        domain = if value.is_empty() { None } else { Some(value.to_lower()) }
      }
      "path" => path = Some(value)
      "secure" => secure = true
      "httponly" => http_only = true
      "samesite" =>
        same_site = match value.to_lower() {
          "strict" => Some(SameSite::Strict)
          "lax" => Some(SameSite::Lax)
          "none" => Some(SameSite::NoRestriction)
          _ => None
        }
      _ => ()
    }
  }
  Some({
    name,
    value,
    expires_ms,
    max_age,
    domain,
    path,
    secure,
    http_only,
    same_site,
  })
}

///|
/// RFC 6265bis-22 §5.6.2: an optional `-` then digits. Magnitudes of 10^18 and
/// more read as 10^18, far past the lifetime cap the caller applies.
fn parse_max_age(text : String) -> Int64? {
  let (negative, digits) = match text.strip_prefix("-") {
    Some(rest) => (true, rest)
    None => (false, text[:])
  }
  guard !digits.is_empty() else { return None }
  let mut value = 0L
  for c in digits {
    guard c.is_ascii_digit() else { return None }
    value = if value < 100_000_000_000_000_000L {
      value * 10L + (c.to_int() - '0'.to_int()).to_int64()
    } else {
      1_000_000_000_000_000_000L
    }
  }
  Some(if negative { -value } else { value })
}

///|
/// Strips leading and trailing SP and HTAB, the WSP of RFC 6265bis-22 §5.6.
fn trim_wsp(text : StringView) -> String {
  text.trim(chars=" \t").to_owned()
}

///|
/// Whether `text` holds a %x00-08 / %x0A-1F / %x7F character. Such a value
/// is ignored whole: it could otherwise carry CR LF into a `Cookie` header.
fn has_control(text : String) -> Bool {
  for c in text {
    let n = c.to_int()
    if (n < 0x20 && n != 0x09) || n == 0x7F {
      return true
    }
  }
  false
}

///|
/// The UTF-8 length of `text`.
fn utf8_length(text : StringView) -> Int32 {
  let mut bytes = 0
  for c in text {
    let n = c.to_int()
    bytes += if n < 0x80 {
      1
    } else if n < 0x800 {
      2
    } else if n < 0x10000 {
      3
    } else {
      4
    }
  }
  bytes
}
