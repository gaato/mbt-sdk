///|
/// `text` in RFC 5952's canonical form if it is an RFC 3986 `IPv6address`:
/// lower-case hex without leading zeros, the longest run of two or more zero
/// groups (the first, if tied) as `::`, and a trailing dotted quad kept
/// where the input had one (RFC 5952 §5). None if it is not an address.
fn ipv6_canonical(text : String) -> String? {
  let halves = text.split("::").to_array()
  guard halves.length() <= 2 else { return None }
  let parsed = []
  let mut dotted = false
  for h, half in halves {
    let groups = []
    if half.length() > 0 {
      let parts = half.split(":").to_array()
      for p, part in parts {
        let last = h == halves.length() - 1 && p == parts.length() - 1
        if last && part.contains(".") {
          guard ipv4_octets(part) is Some(octets) else { return None }
          groups.push(octets[0] * 256 + octets[1])
          groups.push(octets[2] * 256 + octets[3])
          dotted = true
        } else {
          guard part.length() >= 1 &&
            part.length() <= 4 &&
            part.iter().all(c => c.is_ascii_hexdigit()) else {
            return None
          }
          groups.push(
            part.iter().fold(init=0, (value, c) => value * 16 + hex_value(c)),
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
  Some(ipv6_text(groups, dotted~))
}

///|
/// Writes eight groups by RFC 5952 §4, the last two as a dotted quad when
/// `dotted`; the run compressed to `::` is then sought among the first six.
fn ipv6_text(groups : Array[Int32], dotted~ : Bool) -> String {
  let hex_groups = if dotted { 6 } else { 8 }
  let mut best_start = -1
  let mut best_length = 1
  let mut i = 0
  while i < hex_groups {
    if groups[i] != 0 {
      i += 1
      continue
    }
    let start = i
    while i < hex_groups && groups[i] == 0 {
      i += 1
    }
    if i - start > best_length {
      best_start = start
      best_length = i - start
    }
  }
  let builder = StringBuilder()
  let mut i = 0
  while i < hex_groups {
    if i == best_start {
      builder.write_string("::")
      i += best_length
      continue
    }
    if i > 0 && i != best_start + best_length {
      builder.write_char(':')
    }
    builder.write_string(groups[i].to_string(radix=16))
    i += 1
  }
  if dotted {
    if best_start < 0 || best_start + best_length != hex_groups {
      builder.write_char(':')
    }
    let octets = [
      groups[6] >> 8,
      groups[6] & 255,
      groups[7] >> 8,
      groups[7] & 255,
    ]
    builder.write_string(octets.map(octet => octet.to_string()).join("."))
  }
  builder.to_string()
}

///|
/// The four octets of a dotted quad without leading zeros (RFC 3986
/// `dec-octet`), or None.
fn ipv4_octets(text : StringView) -> Array[Int32]? {
  let octets = []
  for octet in text.split(".") {
    guard octet.length() >= 1 &&
      octet.length() <= 3 &&
      octet.iter().all(c => c.is_ascii_digit()) &&
      !(octet.length() > 1 && octet.has_prefix("0")) else {
      return None
    }
    let value = octet
      .iter()
      .fold(init=0, (value, c) => value * 10 + c.to_int() - '0')
    guard value <= 255 else { return None }
    octets.push(value)
  }
  guard octets.length() == 4 else { return None }
  Some(octets)
}

///|
fn hex_value(c : Char) -> Int32 {
  match c {
    '0'..<='9' => c.to_int() - '0'
    'a'..<='f' => c.to_int() - 'a' + 10
    _ => c.to_int() - 'A' + 10
  }
}
