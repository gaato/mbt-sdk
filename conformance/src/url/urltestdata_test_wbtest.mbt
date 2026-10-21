// web-platform-tests' urltestdata.json (see NOTICE) holds the WHATWG URL
// parser's results. `Url` follows RFC 3986 instead, so each row is checked
// unless it falls under one of the differences below, which
// SPECIFICATIONS.md lists as conventions; a row that matches none of them
// must give WHATWG's result or failure.

///|
/// Why a row does not apply, or `None` when it does.
fn not_applicable(input : String, base : String?) -> String? {
  let texts = [input, base.unwrap_or("")]
  if texts.iter().any(text => text.contains("\\")) {
    return Some("backslash")
  }
  if special_without_slashes(input) {
    return Some("special scheme without //")
  }
  if input.to_lower().contains("%2e") {
    return Some("%2e segment")
  }
  if input.find("?") is Some(question) &&
    input[question:].split("#").next().unwrap_or("").contains("'") {
    return Some("' in a query")
  }
  guard authority(input) is Some(authority) else { return None }
  let (userinfo, host) = match authority.rev_find("@") {
    Some(at) => (Some(authority[:at].to_owned()), authority[at + 1:].to_owned())
    None => (None, authority)
  }
  let host = host_without_port(host)
  if host.is_empty() {
    return Some("empty host")
  }
  if host.iter().any(c => c.to_int() >= 0x80 || c == '%') {
    return Some("IDNA or percent-encoded host")
  }
  if host
    .iter()
    .any(c => c is ('"' | '`' | '{' | '}' | '<' | '>' | '^' | '|' | ' ')) {
    return Some("host outside reg-name")
  }
  if host.has_prefix("[") && host.contains(".") {
    return Some("IPv6 with an IPv4 tail")
  }
  if ends_in_number(host) && !dotted_decimal(host) {
    return Some("host ending in a number")
  }
  if userinfo is Some(info) && (info.is_empty() || info.has_suffix(":")) {
    return Some("empty userinfo or password")
  }
  None
}

///|
/// `http:x` or `http:/x`: a special scheme not followed by `//`.
fn special_without_slashes(input : String) -> Bool {
  let lower = input.trim(chars=" \t\n\r").to_lower()
  for scheme in ["http:", "https:", "ws:", "wss:"] {
    if lower.has_prefix(scheme) {
      return !lower[scheme.length():].has_prefix("//")
    }
  }
  false
}

///|
/// The authority after `//`, up to the path, query or fragment.
fn authority(input : String) -> String? {
  let text = input.trim(chars=" \t\n\r")
  guard text.find("//") is Some(start) else { return None }
  let colon = text.find(":").unwrap_or(-1)
  // `//` must open the reference, or follow `scheme:`.
  guard start == 0 || start == colon + 1 else { return None }
  let rest = text[start + 2:]
  let end = rest.find("/").unwrap_or(rest.length())
  let end = end.min(rest.find("?").unwrap_or(rest.length()))
  let end = end.min(rest.find("#").unwrap_or(rest.length()))
  Some(
    rest[:end]
    .to_owned()
    .replace_all(old="\t", new="")
    .replace_all(old="\n", new=""),
  )
}

///|
fn host_without_port(host : String) -> String {
  if host.has_prefix("[") {
    match host.find("]") {
      Some(close) => host[:close + 1].to_owned()
      None => host
    }
  } else {
    match host.rev_find(":") {
      Some(colon) => host[:colon].to_owned()
      None => host
    }
  }
}

///|
/// The WHATWG "ends in a number" test: the last label, after one trailing
/// dot, is decimal digits or starts with `0x`.
fn ends_in_number(host : String) -> Bool {
  let host = host.strip_suffix(".").unwrap_or(host[:])
  let last = match host.rev_find(".") {
    Some(dot) => host[dot + 1:]
    None => host
  }
  !last.is_empty() &&
  (last.iter().all(c => c.is_ascii_digit()) || last.to_lower().has_prefix("0x"))
}

///|
/// RFC 3986's IPv4address: four decimal octets, no leading zeros.
fn dotted_decimal(host : String) -> Bool {
  let parts = host.split(".").collect()
  parts.length() == 4 &&
  parts
  .iter()
  .all(part => {
    !part.is_empty() &&
    part.length() <= 3 &&
    part.iter().all(c => c.is_ascii_digit()) &&
    !(part.length() > 1 && part.has_prefix("0")) &&
    (@string.parse_int(part.to_owned()) catch { _ => 256 }) <= 255
  })
}

///|
/// RFC 9110 §4.2.3: an empty path is equivalent to `/`. WHATWG writes the
/// `/`; `Url` keeps the path as written.
fn with_root_path(href : String) -> String {
  guard href.find("://") is Some(colon) else { return href }
  let start = colon + 3
  let rest = href[start:]
  let end = rest.find("/").unwrap_or(rest.length())
  let end = end.min(rest.find("?").unwrap_or(rest.length()))
  let end = end.min(rest.find("#").unwrap_or(rest.length()))
  if rest[end:].has_prefix("/") {
    href
  } else {
    href[:start + end].to_owned() + "/" + rest[end:].to_owned()
  }
}

///|
fn parse_like_whatwg(input : String, base : String?) -> String {
  try {
    let reference = @http.Url::parse(input)
    match base {
      Some(base) =>
        with_root_path(@http.Url::parse(base).resolve(reference).to_string())
      None if reference.is_absolute() => with_root_path(reference.to_string())
      None => "failure"
    }
  } catch {
    _ => "failure"
  }
}

///|
test "urltestdata gives WHATWG's results where RFC 3986 agrees" {
  guard @json.parse(urltestdata) is Array(rows) else { fail("expected rows") }
  let skipped : Map[String, Int32] = Map([])
  let mut checked = 0
  for row in rows {
    guard row is Object(fields) && fields.get("input") is Some(String(input)) else {
      fail("malformed row \{row.stringify()}")
    }
    let base = match fields.get("base") {
      Some(String(base)) => Some(base)
      _ => None
    }
    let expected = match fields.get("href") {
      Some(String(href)) => href
      _ => "failure"
    }
    if not_applicable(input, base) is Some(reason) {
      skipped[reason] = skipped.get(reason).unwrap_or(0) + 1
      continue
    }
    checked += 1
    assert_eq(
      parse_like_whatwg(input, base),
      expected,
      msg="input \{Repr(input)} base \{Repr(base)}",
    )
  }
  debug_inspect(
    (checked, skipped.to_array()),
    content=(
      #|(
      #|  226,
      #|  [
      #|    ("empty userinfo or password", 6),
      #|    ("special scheme without //", 39),
      #|    ("backslash", 17),
      #|    ("IDNA or percent-encoded host", 78),
      #|    ("IPv6 with an IPv4 tail", 19),
      #|    ("%2e segment", 9),
      #|    ("host ending in a number", 52),
      #|    ("empty host", 13),
      #|    ("host outside reg-name", 10),
      #|    ("' in a query", 2),
      #|  ],
      #|)
    ),
  )
}
