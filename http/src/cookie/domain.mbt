///|
/// Whether a canonical (lowercase) host is an IP address rather than a
/// domain name: a bracketed IPv6 literal, or a host whose last label is a
/// number (the WHATWG URL "ends in a number" rule, which also catches
/// shorthand IPv4 forms such as `127.1` and `0x7f.1`).
fn is_ip_host(host : String) -> Bool {
  if host.has_prefix("[") {
    return true
  }
  let host = host.strip_suffix(".").unwrap_or(host[:])
  let last = match host.rev_find(".") {
    Some(dot) => host[dot + 1:]
    None => host
  }
  if last.is_empty() {
    return false
  }
  let digits = if last.has_prefix("0x") || last.has_prefix("0X") {
    last[2:]
  } else {
    last
  }
  for c in digits {
    guard c.is_ascii_digit() ||
      (digits.length() < last.length() && c.is_ascii_hexdigit()) else {
      return false
    }
  }
  true
}

///|
/// RFC 6265 §5.1.3 domain-match: `host` is `domain`, or ends with `.` then
/// `domain` and is a name rather than an IP address.
fn domain_match(host : String, domain : String) -> Bool {
  host == domain || (host.has_suffix("." + domain) && !is_ip_host(host))
}

///|
/// The one public-suffix rule this package applies without a list: a
/// single-label domain (`com`, `localhost`, a bracketed IPv6 literal) is a
/// public suffix. Under the Public Suffix List every single label is one too
/// (its default rule is `*`), so a list only adds to this rule.
fn is_single_label(domain : String) -> Bool {
  !domain.contains(".")
}

///|
/// The domains whose cookies can match a request to `host`: the host itself
/// and, unless it is an IP address, each parent domain.
fn candidate_domains(host : String) -> Array[String] {
  let domains = [host]
  if !is_ip_host(host) {
    let mut rest = host[:]
    while rest.find(".") is Some(dot) {
      rest = rest[dot + 1:]
      if !rest.is_empty() {
        domains.push(rest.to_owned())
      }
    }
  }
  domains
}
