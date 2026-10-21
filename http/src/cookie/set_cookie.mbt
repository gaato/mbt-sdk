///|
/// The most a `Set-Cookie` value may take, in UTF-8 bytes of its name, value
/// and attributes together: the per-cookie size RFC 6265 §6.1 asks user
/// agents to support. A longer one is ignored whole.
let max_cookie_bytes : Int32 = 4096

///|
/// The most one attribute value may take, in UTF-8 bytes (RFC 6265bis-22
/// §5.6); a longer attribute is ignored.
let max_attribute_bytes : Int32 = 1024

///|
/// A `Set-Cookie` value parsed by RFC 6265 §5.2, before the storage model
/// decides what it means for the request.
priv struct SetCookie {
  name : String
  value : String
  /// The last valid `Expires`, in Unix milliseconds.
  expires_ms : Int64?
  /// The last valid `Max-Age`, in seconds; it overrides `Expires`.
  max_age : Int64?
  /// The last non-empty `Domain`, lowercased, one leading dot removed.
  domain : String?
  /// The last `Path` value, which may still need the default path.
  path : String?
  secure : Bool
  http_only : Bool
  same_site : SameSite?
}

///|
/// Parses a `Set-Cookie` value, or returns `None` when RFC 6265 §5.2 ignores
/// it: no `=` in the name-value pair, an empty name, a control character
/// other than HTAB anywhere (RFC 6265bis-22 §5.6), or more than `max_cookie_bytes`.
/// Unknown and malformed attributes are skipped.
fn parse_set_cookie(text : String) -> SetCookie? {
  guard utf8_length(text) <= max_cookie_bytes && !has_control(text) else {
    return None
  }
  let (pair, attributes) = match text.split_once(";") {
    Some((pair, attributes)) => (pair, attributes)
    None => (text[:], ""[:])
  }
  guard pair.split_once("=") is Some((name, value)) else { return None }
  let name = trim_wsp(name)
  guard !name.is_empty() else { return None }
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
        if !value.is_empty() {
          domain = Some(value.to_lower())
        }
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
    value: trim_wsp(value),
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
/// RFC 6265 §5.2.2: an optional `-` then digits. Magnitudes of 10^18 and
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
/// Strips leading and trailing SP and HTAB, the whitespace of RFC 6265 §5.2.
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
