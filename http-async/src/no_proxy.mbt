///|
/// One entry of a `NO_PROXY` list, as curl reads it.
priv enum NoProxyRule {
  /// `*`: every host.
  Everything
  /// A host name, lower-case without a leading or trailing dot: the host
  /// itself and every subdomain, on `port` or any port.
  Domain(name~ : String, port~ : Int32?)
  /// An IP address, or with `/prefix` a network: the addresses whose first
  /// `prefix` bits match `address` (4 bytes for IPv4, 16 for IPv6), on
  /// `port` or any port.
  Network(address~ : Array[Int32], prefix~ : Int32, port~ : Int32?)
}

///|
/// The rules of a `NO_PROXY` value, by curl's reading: comma-separated
/// entries, spaces around them ignored; `*` for every host; a host name,
/// with or without a leading dot, for itself and its subdomains; an IPv4 or
/// IPv6 address, bracketed or not, optionally a `/prefix` network (curl
/// 7.86, Go, reqwest). `host:port` and `[v6]:port` restrict an entry to that
/// port, as httpx, Go and Python do. Entries that are none of these are
/// skipped, so a typo bypasses nothing.
fn parse_no_proxy(text : String) -> Array[NoProxyRule] {
  let rules = []
  for entry in text.split(",") {
    let entry = entry.trim().to_owned()
    if entry.is_empty() {
      continue
    }
    if no_proxy_rule(entry) is Some(rule) {
      rules.push(rule)
    }
  }
  rules
}

///|
fn no_proxy_rule(entry : String) -> NoProxyRule? {
  if entry == "*" {
    return Some(Everything)
  }
  // `[v6]`, `[v6]:port`, `[v6/prefix]`
  if entry.has_prefix("[") {
    guard entry.find("]") is Some(close) else { return None }
    let after = entry[close + 1:].to_owned()
    let port = if after.is_empty() {
      None
    } else if after.has_prefix(":") {
      guard port_number(after[1:].to_owned()) is Some(port) else { return None }
      Some(port)
    } else {
      return None
    }
    return network_rule(entry[1:close].to_owned(), port~)
  }
  if entry.contains("/") {
    return network_rule(entry, port=None)
  }
  let colons = entry.iter().filter(c => c == ':').count()
  if colons >= 2 {
    return network_rule(entry, port=None)
  }
  let (host, port) = if entry.rev_find(":") is Some(colon) {
    guard port_number(entry[colon + 1:].to_owned()) is Some(port) else {
      return None
    }
    (entry[:colon].to_owned(), Some(port))
  } else {
    (entry, None)
  }
  if ipv4_bytes(host) is Some(address) {
    return Some(Network(address~, prefix=32, port~))
  }
  let mut name = host.to_lower()
  if name.has_prefix(".") {
    name = name[1:].to_owned()
  }
  if name.has_suffix(".") {
    name = name[:name.length() - 1].to_owned()
  }
  guard !name.is_empty() &&
    name.iter().all(c => c is ('a'..<='z' | '0'..<='9' | '-' | '.' | '_')) else {
    return None
  }
  Some(Domain(name~, port~))
}

///|
/// An address or `address/prefix` rule, IPv4 or IPv6.
fn network_rule(text : String, port~ : Int32?) -> NoProxyRule? {
  let (address_text, prefix_text) = match text.find("/") {
    Some(slash) => (text[:slash].to_owned(), Some(text[slash + 1:].to_owned()))
    None => (text, None)
  }
  let address = match ipv4_bytes(address_text) {
    Some(bytes) => bytes
    None => {
      guard ipv6_bytes(address_text) is Some(bytes) else { return None }
      bytes
    }
  }
  let bits = address.length() * 8
  let prefix = match prefix_text {
    None => bits
    Some(digits) => {
      guard !digits.is_empty() &&
        digits.length() <= 3 &&
        digits.iter().all(c => c.is_ascii_digit()) else {
        return None
      }
      let prefix = digits
        .iter()
        .fold(init=0, (n, c) => n * 10 + (c.to_int() - '0'.to_int()))
      guard prefix <= bits else { return None }
      prefix
    }
  }
  Some(Network(address~, prefix~, port~))
}

///|
/// Whether a request to `host` on `port` skips the proxy. `host` is as a
/// canonical origin spells it: lower-case, an IPv6 literal without brackets.
/// Host names are compared as text and never resolved, so an address rule
/// matches only a URL written with that address.
fn bypasses_proxy(
  rules : Array[NoProxyRule],
  host : String,
  port : Int32,
) -> Bool {
  let host = if host.has_suffix(".") {
    host[:host.length() - 1].to_owned()
  } else {
    host
  }
  let address = match ipv4_bytes(host) {
    Some(bytes) => Some(bytes)
    None => if host.contains(":") { ipv6_bytes(host) } else { None }
  }
  rules.any(rule => {
    match rule {
      Everything => true
      Domain(name~, port=rule_port) =>
        address is None &&
        port_matches(rule_port, port) &&
        (host == name || host.has_suffix("." + name))
      Network(address=network, prefix~, port=rule_port) =>
        port_matches(rule_port, port) &&
        address is Some(bytes) &&
        in_network(bytes, network, prefix)
    }
  })
}

///|
fn port_matches(rule : Int32?, port : Int32) -> Bool {
  match rule {
    None => true
    Some(wanted) => wanted == port
  }
}

///|
/// Whether `address` shares its first `prefix` bits with `network`, both of
/// one family.
fn in_network(
  address : Array[Int32],
  network : Array[Int32],
  prefix : Int32,
) -> Bool {
  guard address.length() == network.length() else { return false }
  for i in 0..<address.length() {
    let bits = (prefix - i * 8).max(0).min(8)
    if bits == 0 {
      break
    }
    let mask = (0xff << (8 - bits)) & 0xff
    if (address[i] & mask) != (network[i] & mask) {
      return false
    }
  }
  true
}

///|
/// A port number from 1 to 65535 in decimal digits.
fn port_number(text : String) -> Int32? {
  guard !text.is_empty() &&
    text.length() <= 5 &&
    text.iter().all(c => c.is_ascii_digit()) else {
    return None
  }
  let port = text
    .iter()
    .fold(init=0, (n, c) => n * 10 + (c.to_int() - '0'.to_int()))
  if port >= 1 && port <= 65535 {
    Some(port)
  } else {
    None
  }
}

///|
/// The four bytes of a dotted-decimal IPv4 address.
fn ipv4_bytes(text : String) -> Array[Int32]? {
  let parts = text.split(".").to_array()
  guard parts.length() == 4 else { return None }
  let bytes = []
  for part in parts {
    guard !part.is_empty() &&
      part.length() <= 3 &&
      part.iter().all(c => c.is_ascii_digit()) else {
      return None
    }
    let value = part
      .iter()
      .fold(init=0, (n, c) => n * 10 + (c.to_int() - '0'.to_int()))
    guard value <= 255 else { return None }
    bytes.push(value)
  }
  Some(bytes)
}

///|
/// The sixteen bytes of an RFC 4291 IPv6 address: hex groups with at most
/// one `::`, the last 32 bits optionally a dotted quad. Zone identifiers
/// are refused.
fn ipv6_bytes(text : String) -> Array[Int32]? {
  let halves = text.split("::").to_array()
  guard halves.length() <= 2 else { return None }
  let parsed : Array[Array[Int32]] = []
  for h, half in halves {
    let groups = []
    if !half.is_empty() {
      let parts = half.split(":").to_array()
      for p, part in parts {
        let last = h == halves.length() - 1 && p == parts.length() - 1
        if last && part.contains(".") {
          guard ipv4_bytes(part.to_owned()) is Some(quad) else { return None }
          groups.push(quad[0] * 256 + quad[1])
          groups.push(quad[2] * 256 + quad[3])
        } else {
          guard part.length() >= 1 &&
            part.length() <= 4 &&
            part.iter().all(c => c.is_ascii_hexdigit()) else {
            return None
          }
          groups.push(
            part.iter().fold(init=0, (n, c) => n * 16 + hex_digit_value(c)),
          )
        }
      }
    }
    parsed.push(groups)
  }
  let groups = if parsed.length() == 2 {
    let missing = 8 - parsed[0].length() - parsed[1].length()
    guard missing >= 1 else { return None }
    [..parsed[0], ..Array::make(missing, 0), ..parsed[1]]
  } else {
    guard parsed[0].length() == 8 else { return None }
    parsed[0]
  }
  let bytes = []
  for group in groups {
    bytes.push(group >> 8)
    bytes.push(group & 0xff)
  }
  Some(bytes)
}

///|
fn hex_digit_value(c : Char) -> Int32 {
  match c {
    '0'..<='9' => c.to_int() - '0'.to_int()
    'a'..<='f' => c.to_int() - 'a'.to_int() + 10
    _ => c.to_int() - 'A'.to_int() + 10
  }
}
