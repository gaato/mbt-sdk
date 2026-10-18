///|
/// Percent-encodes UTF-8 bytes, preserving only RFC 3986 unreserved bytes.
pub fn percent_encode(value : String) -> String {
  @percent.encode(value)
}

///|
/// Percent-encodes a multi-segment path, also preserving slash separators.
pub fn percent_encode_path(value : String) -> String {
  let builder = StringBuilder()
  for i, segment in value.split("/") {
    if i > 0 {
      builder.write_char('/')
    }
    builder.write_string(@percent.encode(segment))
  }
  builder.to_string()
}

///|
/// Appends an encoded query pair, using ampersand if the URL contains `?`.
pub fn append_query(url : String, name : String, value : String) -> String {
  let separator = if url.contains("?") { "&" } else { "?" }
  url + separator + percent_encode(name) + "=" + percent_encode(value)
}

// The URI reference below follows RFC 3986. Its split, `remove_dot_segments`
// loop and §5.2.2 resolution are ported from moonbitstack/moonhttp's `url`
// package (Copyright 2026 Leo Cheng, Apache-2.0); the percent-encode sets
// follow the WHATWG URL Standard.

///|
/// A URI reference (RFC 3986 §4.1), held normalised and percent-encoded.
///
/// `Url::parse` lower-cases the scheme and host, writes an IPv6 address in
/// RFC 5952's canonical form, drops a scheme's default
/// port (`http` 80, `https` 443, `ws` 80, `wss` 443, `ftp` 21), percent-encodes
/// what the WHATWG URL Standard's sets encode (non-ASCII as UTF-8), and removes
/// dot segments from the path of a reference with a scheme. Existing escapes
/// are kept as written. No `scheme` makes the reference relative; no `host`
/// means no authority, which is not an empty host. A host is ASCII only:
/// internationalised domain names (IDNA) are refused, so pass their `xn--`
/// form.
///
/// ```mbt check
/// test {
///   let base = @http.Url::parse("HTTPS://Example.COM:443/a/b?x=1")
///   assert_eq(base.to_string(), "https://example.com/a/b?x=1")
///   let next = base.resolve(@http.Url::parse("../c d"))
///   assert_eq(next.to_string(), "https://example.com/c%20d")
/// }
/// ```
pub struct Url {
  scheme : String?
  userinfo : String?
  host : String?
  port : Int32?
  path : String
  query : String?
  fragment : String?
} derive(Eq, Debug)

///|
/// Compares all components; parsing has already normalised them.
pub extend Url with Eq::{equal, not_equal}

///|
/// Debug representation of the components.
pub extend Url with @debug.Debug::{to_repr}

///|
/// Why a string is not a URI reference this package accepts.
pub(all) suberror UrlError {
  Invalid(String)
} derive(Eq, Debug)

///|
/// Compares refusals by their reason.
pub extend UrlError with Eq::{equal, not_equal}

///|
/// Debug representation of a refused URL.
pub extend UrlError with @debug.Debug::{to_repr}

///|
/// Parses a URI reference, absolute or relative.
///
/// Leading and trailing C0 controls and spaces are trimmed and tabs and line
/// breaks removed, as browsers do. Only the authority can be refused: a port
/// that is not a decimal number up to 65535, an IP literal that is not an
/// IPv6 address (zone identifiers and IPvFuture included), or a host with a
/// character outside RFC 3986's `reg-name` — non-ASCII and percent-encoded
/// hosts among them, since IDNA is out of scope. A backslash is data, not a
/// separator, and is percent-encoded.
pub fn Url::parse(text : String) -> Url raise UrlError {
  let chars = url_chars(text)
  let n = chars.length()
  let mut i = 0
  let scheme = match url_scheme(chars) {
    Some(name) => {
      i = name.length() + 1
      Some(name.to_lower())
    }
    None => None
  }
  let mut userinfo = None
  let mut host = None
  let mut port = None
  if i + 1 < n && chars[i] == '/' && chars[i + 1] == '/' {
    i += 2
    let start = i
    while i < n && chars[i] != '/' && chars[i] != '?' && chars[i] != '#' {
      i += 1
    }
    let (u, h, p) = url_authority(chars[start:i])
    userinfo = u
    host = Some(h)
    port = p
  }
  let start = i
  while i < n && chars[i] != '?' && chars[i] != '#' {
    i += 1
  }
  let path = url_encode(chars[start:i], path_byte)
  let mut query = None
  if i < n && chars[i] == '?' {
    i += 1
    let start = i
    while i < n && chars[i] != '#' {
      i += 1
    }
    query = Some(url_encode(chars[start:i], query_byte))
  }
  let fragment = if i < n && chars[i] == '#' {
    Some(url_encode(chars[i + 1:], fragment_byte))
  } else {
    None
  }
  {
    scheme,
    userinfo,
    host,
    port: url_port(scheme, port),
    path: if scheme is Some(_) {
      remove_dot_segments(path)
    } else {
      path
    },
    query,
    fragment,
  }
}

///|
/// Serialises the reference (RFC 3986 §5.3). A path that would read as an
/// authority or a scheme gets a `/.` or `./` prefix, as the WHATWG URL
/// Standard does, so the result parses back to the same reference.
pub impl Show for Url with fn output(self, logger) {
  if self.scheme is Some(scheme) {
    logger.write_string(scheme)
    logger.write_char(':')
  }
  match self.host {
    Some(host) => {
      logger.write_string("//")
      if self.userinfo is Some(userinfo) {
        logger.write_string(userinfo)
        logger.write_char('@')
      }
      if host.contains(":") {
        logger.write_char('[')
        logger.write_string(host)
        logger.write_char(']')
      } else {
        logger.write_string(host)
      }
      if self.port is Some(port) {
        logger.write_char(':')
        logger.write_string(port.to_string())
      }
    }
    None =>
      if self.path.has_prefix("//") {
        logger.write_string("/.")
      } else if self.scheme is None && url_colon_first(self.path) {
        logger.write_string("./")
      }
  }
  logger.write_string(self.path)
  if self.query is Some(query) {
    logger.write_char('?')
    logger.write_string(query)
  }
  if self.fragment is Some(fragment) {
    logger.write_char('#')
    logger.write_string(fragment)
  }
}

///|
/// The serialised reference.
pub extend Url with Show::{output, to_string}

///|
/// Reports whether the reference has a scheme.
pub fn Url::is_absolute(self : Url) -> Bool {
  self.scheme is Some(_)
}

///|
/// The port, or the scheme's default when the URL names none.
pub fn Url::port_or_default(self : Url) -> Int32? {
  match self.port {
    Some(_) => self.port
    None => self.scheme.bind(default_port)
  }
}

///|
/// Reports whether both URLs have the same scheme, host and port, counting
/// the scheme's default port. A URL without a scheme or host has no origin
/// and matches nothing.
pub fn Url::same_origin(self : Url, other : Url) -> Bool {
  self.scheme is Some(_) &&
  self.host is Some(_) &&
  self.scheme == other.scheme &&
  self.host == other.host &&
  self.port_or_default() == other.port_or_default()
}

///|
/// The same URL without its fragment, which is never sent to a server.
pub fn Url::without_fragment(self : Url) -> Url {
  { ..self, fragment: None, }
}

///|
/// Resolves `reference` against this base (RFC 3986 §5.2.2, strict): a
/// reference with a scheme, even the base's own, stays absolute. The base
/// should be absolute; RFC 3986 defines no result otherwise.
///
/// ```mbt check
/// test {
///   let base = @http.Url::parse("http://a/b/c/d;p?q")
///   assert_eq(base.resolve(@http.Url::parse("../g")).to_string(), "http://a/b/g")
///   assert_eq(base.resolve(@http.Url::parse("//g")).to_string(), "http://g")
/// }
/// ```
pub fn Url::resolve(self : Url, reference : Url) -> Url {
  if reference.scheme is Some(_) {
    return { ..reference, path: remove_dot_segments(reference.path), }
  }
  if reference.host is Some(_) {
    return {
      ..reference,
      scheme: self.scheme,
      port: url_port(self.scheme, reference.port),
      path: remove_dot_segments(reference.path),
    }
  }
  if reference.path == "" {
    let query = match reference.query {
      Some(_) => reference.query
      None => self.query
    }
    return { ..self, query, fragment: reference.fragment, }
  }
  let path = if reference.path.has_prefix("/") {
    remove_dot_segments(reference.path)
  } else {
    remove_dot_segments(merge_paths(self, reference.path))
  }
  { ..self, path, query: reference.query, fragment: reference.fragment, }
}

///|
/// The query's name-value pairs, decoded as `application/x-www-form-urlencoded`:
/// `+` is a space, escapes are UTF-8 (malformed ones are kept literally), empty
/// pairs are skipped and a pair without `=` has an empty value.
pub fn Url::query_params(self : Url) -> Array[(String, String)] {
  guard self.query is Some(query) else { return [] }
  let params = []
  for piece in query.split("&") {
    if piece.length() > 0 {
      params.push(query_pair(piece))
    }
  }
  params
}

///|
/// Appends encoded pairs after the existing query, keeping it as written.
/// Names and values keep only RFC 3986 unreserved characters, as
/// `percent_encode` does.
///
/// ```mbt check
/// test {
///   let url = @http.Url::parse("https://h/p?a=1#top")
///   let next = url.append_query_params([("b", "x y"), ("a", "2")])
///   assert_eq(next.to_string(), "https://h/p?a=1&b=x%20y&a=2#top")
/// }
/// ```
pub fn Url::append_query_params(
  self : Url,
  params : Array[(String, String)],
) -> Url {
  if params.is_empty() {
    return self
  }
  let builder = StringBuilder()
  if self.query is Some(query) {
    builder.write_string(query)
    if query.length() > 0 && !query.has_suffix("&") {
      builder.write_char('&')
    }
  }
  for i, pair in params {
    if i > 0 {
      builder.write_char('&')
    }
    builder.write_string(percent_encode(pair.0))
    builder.write_char('=')
    builder.write_string(percent_encode(pair.1))
  }
  { ..self, query: Some(builder.to_string()), }
}

///|
/// Replaces every existing pair whose decoded name is among `params`' names,
/// then appends `params` in order, as httpx's `merge_params` does. The pairs
/// kept are kept as written.
///
/// ```mbt check
/// test {
///   let url = @http.Url::parse("https://h/p?page=1&q=a+b&page=2")
///   let next = url.merge_query_params([("page", "3")])
///   assert_eq(next.to_string(), "https://h/p?q=a+b&page=3")
/// }
/// ```
pub fn Url::merge_query_params(
  self : Url,
  params : Array[(String, String)],
) -> Url {
  if params.is_empty() {
    return self
  }
  let names = params.map(pair => pair.0)
  let kept = []
  if self.query is Some(query) {
    for piece in query.split("&") {
      if piece.length() > 0 && !names.contains(query_pair(piece).0) {
        kept.push(piece.to_owned())
      }
    }
  }
  { ..self, query: Some(kept.join("&")), }.append_query_params(params)
}

///|
/// Removes `.` and `..` segments (RFC 3986 §5.2.4), by the section's loop: a
/// split-and-join differs at a trailing `..`, a path climbing above its root,
/// and `/..//`.
fn remove_dot_segments(path : String) -> String {
  let output : Array[StringView] = []
  let mut rest = path[:]
  while rest.length() > 0 {
    if rest.has_prefix("../") {
      rest = rest[3:]
    } else if rest.has_prefix("./") {
      rest = rest[2:]
    } else if rest.has_prefix("/./") {
      rest = rest[2:]
    } else if rest == "/." {
      rest = "/"
    } else if rest.has_prefix("/../") {
      rest = rest[3:]
      let _ = output.pop()
    } else if rest == "/.." {
      rest = "/"
      let _ = output.pop()
    } else if rest == "." || rest == ".." {
      rest = ""
    } else {
      let mut end = if rest.has_prefix("/") { 1 } else { 0 }
      while end < rest.length() && rest[end] != '/' {
        end += 1
      }
      output.push(rest[:end])
      rest = rest[end:]
    }
  }
  let builder = StringBuilder()
  for segment in output {
    builder.write_view(segment)
  }
  builder.to_string()
}

///|
/// Grafts a relative path onto the base's directory (RFC 3986 §5.2.3).
fn merge_paths(base : Url, path : String) -> String {
  if base.host is Some(_) && base.path == "" {
    return "/" + path
  }
  match base.path.rev_find("/") {
    Some(cut) => base.path[:cut + 1].to_owned() + path
    None => path
  }
}

///|
/// The input as characters, trimmed of C0 controls and spaces at both ends and
/// without tabs and line breaks (WHATWG URL parsing).
fn url_chars(text : String) -> Array[Char] {
  let chars = []
  for c in text.trim(chars=url_trimmed) {
    if c != '\t' && c != '\n' && c != '\r' {
      chars.push(c)
    }
  }
  chars
}

///|
let url_trimmed : String = {
  let builder = StringBuilder()
  for code = 0; code <= 0x20; code = code + 1 {
    builder.write_char(code.unsafe_to_char())
  }
  builder.to_string()
}

///|
/// The scheme, if the reference starts with one (RFC 3986 §3.1): a letter,
/// then letters, digits, `+`, `-` or `.`, then a colon. `a/b:c` and `1:a`
/// have none.
fn url_scheme(chars : Array[Char]) -> String? {
  guard chars.length() > 0 && chars[0].is_ascii_alphabetic() else {
    return None
  }
  for i = 1; i < chars.length(); i = i + 1 {
    let c = chars[i]
    if c == ':' {
      return Some(String::from_array(chars[:i]))
    }
    guard c.is_ascii_alphabetic() ||
      c.is_ascii_digit() ||
      c == '+' ||
      c == '-' ||
      c == '.' else {
      return None
    }
  }
  None
}

///|
/// Splits an authority into userinfo, host and port (RFC 3986 §3.2). The last
/// `@` divides: a second one belongs to the userinfo and is encoded.
fn url_authority(
  chars : ArrayView[Char],
) -> (String?, String, Int32?) raise UrlError {
  let mut cut = -1
  for i, c in chars {
    if c == '@' {
      cut = i
    }
  }
  let userinfo = if cut >= 0 { Some(url_userinfo(chars[:cut])) } else { None }
  let rest = chars[cut + 1:]
  let (host, after) = if rest.length() > 0 && rest[0] == '[' {
    guard rest.iter().find_first(c => c == ']') is Some(_) else {
      raise Invalid("IP literal without a closing bracket")
    }
    let mut close = 1
    while rest[close] != ']' {
      close += 1
    }
    (ip_literal(rest[1:close]), rest[close + 1:])
  } else {
    let mut end = 0
    while end < rest.length() && rest[end] != ':' {
      end += 1
    }
    (reg_name(rest[:end]), rest[end:])
  }
  if after.length() == 0 {
    return (userinfo, host, None)
  }
  guard after[0] == ':' else {
    raise Invalid("unexpected character after an IP literal")
  }
  (userinfo, host, port_number(after[1:]))
}

///|
/// A userinfo, its user and password encoded separately so the first colon
/// stays the separator.
fn url_userinfo(chars : ArrayView[Char]) -> String {
  match chars.iter().find_first(c => c == ':') {
    None => url_encode(chars, userinfo_byte)
    Some(_) => {
      let mut colon = 0
      while chars[colon] != ':' {
        colon += 1
      }
      url_encode(chars[:colon], userinfo_byte) +
      ":" +
      url_encode(chars[colon + 1:], userinfo_byte)
    }
  }
}

///|
/// A decimal port up to 65535; empty means none (RFC 3986 §3.2.3).
fn port_number(chars : ArrayView[Char]) -> Int32? raise UrlError {
  if chars.length() == 0 {
    return None
  }
  let mut value = 0
  for c in chars {
    guard c.is_ascii_digit() else { raise Invalid("port is not a number") }
    value = value * 10 + (c.to_int() - '0'.to_int())
    guard value <= 65535 else { raise Invalid("port exceeds 65535") }
  }
  Some(value)
}

///|
/// A registered name, lower-cased: RFC 3986 `reg-name` without
/// percent-encoding, so ASCII letters, digits, `-._~` and sub-delimiters.
fn reg_name(chars : ArrayView[Char]) -> String raise UrlError {
  for c in chars {
    guard c.to_int() < 0x80 else {
      raise Invalid("non-ASCII host; pass its IDNA (xn--) form")
    }
    guard unreserved_byte(c.to_int()) || sub_delim_byte(c.to_int()) else {
      raise Invalid("host contains " + c.to_string().escape())
    }
  }
  String::from_array(chars).to_lower()
}

///|
/// An IPv6 address between brackets, in RFC 5952's canonical text form.
/// Zone identifiers and IPvFuture are refused, as browsers refuse them.
fn ip_literal(chars : ArrayView[Char]) -> String raise UrlError {
  guard ipv6_canonical(String::from_array(chars)) is Some(text) else {
    raise Invalid("IP literal is not IPv6")
  }
  text
}

///|
/// Drops the scheme's default port.
fn url_port(scheme : String?, port : Int32?) -> Int32? {
  match (scheme.bind(default_port), port) {
    (Some(default), Some(given)) if default == given => None
    _ => port
  }
}

///|
fn default_port(scheme : String) -> Int32? {
  match scheme {
    "http" | "ws" => Some(80)
    "https" | "wss" => Some(443)
    "ftp" => Some(21)
    _ => None
  }
}

///|
/// Whether a path's first segment contains a colon, which would read as a
/// scheme in a relative reference (RFC 3986 §4.2).
fn url_colon_first(path : String) -> Bool {
  for c in path {
    if c == '/' {
      return false
    }
    if c == ':' {
      return true
    }
  }
  false
}

///|
/// Percent-encodes the characters `keep` does not keep, non-ASCII as UTF-8.
/// A `%` is kept, so existing escapes pass through.
fn url_encode(chars : ArrayView[Char], keep : (Int32) -> Bool) -> String {
  let builder = StringBuilder()
  for c in chars {
    let code = c.to_int()
    if code < 0x80 && keep(code) {
      builder.write_char(c)
    } else {
      for byte in encode_utf8(c.to_string()) {
        let b = byte.to_int()
        builder.write_char('%')
        builder.write_char(hex_digit(b >> 4))
        builder.write_char(hex_digit(b & 15))
      }
    }
  }
  builder.to_string()
}

///|
fn hex_digit(value : Int32) -> Char {
  "0123456789ABCDEF"[value].unsafe_to_char()
}

///|
/// WHATWG's C0 control percent-encode set, complemented: printable ASCII.
fn printable_byte(b : Int32) -> Bool {
  b > 0x20 && b < 0x7F
}

///|
/// WHATWG's fragment percent-encode set, complemented.
fn fragment_byte(b : Int32) -> Bool {
  printable_byte(b) && b != '"' && b != '<' && b != '>' && b != '`'
}

///|
/// WHATWG's query percent-encode set, complemented. The special-scheme `'`
/// is left alone, so a relative reference encodes as its resolution does.
fn query_byte(b : Int32) -> Bool {
  printable_byte(b) && b != '"' && b != '#' && b != '<' && b != '>'
}

///|
/// WHATWG's path percent-encode set, complemented, also encoding the
/// backslash this parser does not read as a slash.
fn path_byte(b : Int32) -> Bool {
  query_byte(b) &&
  b != '?' &&
  b != '^' &&
  b != '`' &&
  b != '{' &&
  b != '}' &&
  b != '\\'
}

///|
/// WHATWG's userinfo percent-encode set, complemented.
fn userinfo_byte(b : Int32) -> Bool {
  path_byte(b) &&
  b != '/' &&
  b != ':' &&
  b != ';' &&
  b != '=' &&
  b != '@' &&
  !(b >= '[' && b <= '^') &&
  b != '|'
}

///|
fn unreserved_byte(b : Int32) -> Bool {
  (b >= 'a' && b <= 'z') ||
  (b >= 'A' && b <= 'Z') ||
  (b >= '0' && b <= '9') ||
  b == '-' ||
  b == '.' ||
  b == '_' ||
  b == '~'
}

///|
fn sub_delim_byte(b : Int32) -> Bool {
  b == '!' ||
  b == '$' ||
  b == '&' ||
  b == '\'' ||
  b == '(' ||
  b == ')' ||
  b == '*' ||
  b == '+' ||
  b == ',' ||
  b == ';' ||
  b == '='
}

///|
/// One query piece split at its first `=` and form-decoded.
fn query_pair(piece : StringView) -> (String, String) {
  let (name, value) = match piece.find("=") {
    Some(i) => (piece[:i], piece[i + 1:])
    None => (piece, "")
  }
  (form_decode(name), form_decode(value))
}

///|
fn form_decode(text : StringView) -> String {
  @percent.decode_lossy(text.to_owned().replace_all(old="+", new=" "))
}
