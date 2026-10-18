///|
/// The parts of a request URL the cookie algorithms read, taken from
/// `@http.Url` so that hosts, ports and paths are read as the rest of the
/// stack reads them.
priv struct RequestUrl {
  /// Lowercase scheme, without `:`.
  scheme : String
  /// The canonical host: lowercase, an IPv6 address in RFC 5952 form inside
  /// brackets. Never empty.
  host : String
  /// The normalised path, without query or fragment; `/` when it is empty.
  path : String
}

///|
/// Reads an absolute URL with a non-empty host, or returns `None`: a relative
/// reference, one without an authority, an empty host, or anything
/// `@http.Url::parse` refuses (a non-ASCII host among them).
fn parse_request_url(text : String) -> RequestUrl? {
  let url = @http.Url::parse(text) catch { _ => return None }
  guard url.scheme is Some(scheme) && url.host is Some(host) && !host.is_empty() else {
    return None
  }
  Some({
    scheme,
    host: if host.contains(":") {
      "[" + host + "]"
    } else {
      host
    },
    path: if url.path.is_empty() {
      "/"
    } else {
      url.path
    },
  })
}

///|
/// The canonical form of a `Domain` attribute that names an IPv6 literal, so
/// that it compares equal to the request host however it is written; any
/// other value is returned as it is.
fn canonical_ip_literal(domain : String) -> String {
  guard domain.has_prefix("[") &&
    domain.has_suffix("]") &&
    parse_request_url("http://" + domain) is Some(url) else {
    return domain
  }
  url.host
}

///|
/// Whether the scheme is one a Secure cookie may be set over or sent to.
fn RequestUrl::is_secure(self : RequestUrl) -> Bool {
  self.scheme == "https" || self.scheme == "wss"
}
