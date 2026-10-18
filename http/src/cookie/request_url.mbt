///|
/// The parts of a request URL the cookie algorithms read. A deliberately tiny
/// private parser: it is meant to be swapped for gaato/http's URL type once
/// that exists, and nothing outside this package sees it.
priv struct RequestUrl {
  /// ASCII-lowercased scheme, without `://`.
  scheme : String
  /// ASCII-lowercased host without userinfo or port; IPv6 keeps its brackets.
  host : String
  /// The path, without query or fragment; `/` when the URL has none.
  path : String
}

///|
/// Splits `scheme://[userinfo@]host[:port][path][?query][#fragment]`, or
/// returns `None` when there is no scheme, no authority or an empty host.
fn parse_request_url(url : String) -> RequestUrl? {
  guard url.find("://") is Some(scheme_end) && scheme_end > 0 else {
    return None
  }
  let scheme = url[:scheme_end].to_owned().to_lower()
  for i, c in scheme {
    guard c.is_ascii_alphabetic() ||
      (i > 0 && (c.is_ascii_digit() || c == '+' || c == '-' || c == '.')) else {
      return None
    }
  }
  let rest = url[scheme_end + 3:]
  let end = first_of(rest, ["/", "?", "#"])
  let authority = rest[:end]
  let host_start = match authority.rev_find("@") {
    Some(at) => at + 1
    None => 0
  }
  let host_port = authority[host_start:]
  let host = if host_port.has_prefix("[") {
    match host_port.find("]") {
      Some(close) => host_port[:close + 1]
      None => return None
    }
  } else {
    match host_port.find(":") {
      Some(colon) => host_port[:colon]
      None => host_port
    }
  }
  guard !host.is_empty() else { return None }
  let tail = rest[end:]
  let path = tail[:first_of(tail, ["?", "#"])].to_owned()
  Some({
    scheme,
    host: host.to_owned().to_lower(),
    path: if path.is_empty() {
      "/"
    } else {
      path
    },
  })
}

///|
/// Whether the scheme is one a Secure cookie may be set over or sent to.
fn RequestUrl::is_secure(self : RequestUrl) -> Bool {
  self.scheme == "https" || self.scheme == "wss"
}

///|
/// The offset of the first of `needles` in `text`, or its length.
fn first_of(text : StringView, needles : Array[String]) -> Int32 {
  let mut end = text.length()
  for needle in needles {
    if text.find(needle) is Some(i) && i < end {
      end = i
    }
  }
  end
}
