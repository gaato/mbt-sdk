///|
/// Cookies kept per domain by default: the minimum RFC 6265 §6.1 asks of a
/// user agent.
let default_max_per_domain : Int32 = 50

///|
/// Cookies kept in a jar by default: the RFC 6265 §6.1 minimum.
let default_max_total : Int32 = 3000

///|
/// The longest a cookie lives, 400 days: a later `Expires` or larger
/// `Max-Age` is cut to it, as RFC 6265bis-22 §5.5 and browsers do.
let max_lifetime_ms : Int64 = 400L * 86_400_000L

///|
/// A stored cookie and its place in creation order, which breaks ties
/// between cookies created or accessed in the same millisecond.
priv struct Entry {
  mut cookie : Cookie
  sequence : Int32
}

///|
/// An RFC 6265bis-22 cookie store for an HTTP client: `store` takes the
/// `Set-Cookie` headers of a response, `header_for` builds the `Cookie`
/// header of a request.
///
/// It is a client's jar, not a browser's: `HttpOnly` cookies are sent like
/// any other, and `SameSite` is kept but not enforced, since a client has no
/// notion of a cross-site request. Without the Public Suffix List it rejects
/// only a `Domain` of a single label (`com`, `localhost`); pass
/// `is_public_suffix` to reject more. An IP-address host only gets host-only
/// cookies. Hosts must arrive in ASCII form, so a `Domain` with other
/// characters is ignored.
///
/// ```mbt check
/// test {
///   let jar = @cookie.CookieJar::new(@mock.FakeClock::new())
///   jar.store(
///     @http.Headers::from_array([("Set-Cookie", "sid=1; Path=/; Secure")]),
///     "https://example.com/login",
///   )
///   assert_eq(jar.header_for("https://example.com/"), Some("sid=1"))
///   assert_eq(jar.header_for("http://example.com/"), None)
/// }
/// ```
pub struct CookieJar {
  priv clock : &@clock.Clock
  priv max_per_domain : Int32
  priv max_total : Int32
  priv is_public_suffix : (String) -> Bool
  /// Entries keyed by their cookie's domain.
  priv domains : Map[String, Array[Entry]]
  priv mut total : Int32
  priv mut next_sequence : Int32
}

///|
/// Creates an empty jar that reads the time from `clock`.
///
/// `max_per_domain` (default 50) and `max_total` (default 3000) bound how many
/// cookies it keeps; a cookie past either evicts expired cookies first, then
/// the least recently accessed, those that are not Secure first when a
/// domain is over its cap (RFC 6265bis-22 §5.7). Negative limits count as 0.
/// `is_public_suffix` names further domains a cookie may not be set for, such
/// as a Public Suffix List lookup; single-label domains are always refused.
pub fn CookieJar::new(
  clock : &@clock.Clock,
  max_per_domain~ : Int32 = default_max_per_domain,
  max_total~ : Int32 = default_max_total,
  is_public_suffix~ : (String) -> Bool = _ => false,
) -> CookieJar {
  {
    clock,
    max_per_domain: max_per_domain.max(0),
    max_total: max_total.max(0),
    is_public_suffix,
    domains: Map([]),
    total: 0,
    next_sequence: 0,
  }
}

///|
/// Stores every `Set-Cookie` of a response to `request_url`, in order.
/// Values the RFC 6265 algorithms ignore, and every value when the URL has no
/// host, are skipped.
pub fn CookieJar::store(
  self : CookieJar,
  headers : @http.Headers,
  request_url : String,
) -> Unit {
  guard parse_request_url(request_url) is Some(url) else { return }
  let now_ms = self.clock.now_unix_ms()
  for value in headers.get_all("set-cookie") {
    self.store_at(url, value, now_ms)
  }
}

///|
/// Returns the `Cookie` header value for a request to `request_url`, or
/// `None` when no cookie matches, and marks the cookies sent as accessed.
/// Longer paths come first, then earlier-created cookies (RFC 6265bis-22 §5.8.3).
pub fn CookieJar::header_for(self : CookieJar, request_url : String) -> String? {
  guard parse_request_url(request_url) is Some(url) else { return None }
  self.header_at(url, self.clock.now_unix_ms())
}

///|
/// The number of cookies stored, expired ones not yet evicted included.
pub fn CookieJar::length(self : CookieJar) -> Int32 {
  self.total
}

///|
/// Iterates over a snapshot of the stored cookies, grouped by domain.
/// Expired cookies not yet evicted are included; see `remove_expired`.
pub fn CookieJar::iter(self : CookieJar) -> Iter[Cookie] {
  let cookies = []
  for _, entries in self.domains {
    for entry in entries {
      cookies.push(entry.cookie)
    }
  }
  cookies.iter()
}

///|
/// Removes every cookie.
pub fn CookieJar::clear(self : CookieJar) -> Unit {
  self.domains.clear()
  self.total = 0
}

///|
/// Removes the cookies whose domain is `domain` or one of its subdomains.
pub fn CookieJar::clear_domain(self : CookieJar, domain : String) -> Unit {
  let domain = domain.to_lower()
  self.remove_where(cookie => domain_match(cookie.domain, domain))
}

///|
/// Removes the session cookies (those without `Expires` or `Max-Age`), as
/// RFC 6265bis-22 §5.7 does when the session is over.
pub fn CookieJar::clear_session(self : CookieJar) -> Unit {
  self.remove_where(cookie => cookie.expires_ms is None)
}

///|
/// Removes the cookies that have expired by the clock's current time.
pub fn CookieJar::remove_expired(self : CookieJar) -> Unit {
  let now_ms = self.clock.now_unix_ms()
  self.remove_where(cookie => cookie.is_expired(now_ms))
}

///|
/// The RFC 6265bis-22 §5.7 storage model for one `Set-Cookie` value received
/// at `now_ms`: Secure cookies only from secure origins (step 13), no
/// insecure overwrite of a Secure cookie (step 16), `SameSite=None` only
/// when Secure (step 19), and the `__Secure-` and `__Host-` prefixes (steps
/// 20–22). Step 18, which refuses cookies from cross-site requests, does not
/// apply: a client has no notion of a site. Expired cookies are evicted
/// first (§5.7 asks for that whenever one exists), so none of these rules,
/// the replacement of a cookie or the caps ever consult one.
fn CookieJar::store_at(
  self : CookieJar,
  url : RequestUrl,
  text : String,
  now_ms : Int64,
) -> Unit {
  guard parse_set_cookie(text) is Some(parsed) else { return }
  self.remove_where(cookie => cookie.is_expired(now_ms))
  guard self.cookie_domain(url.host, parsed.domain) is Some((domain, host_only)) else {
    return
  }
  let path = match parsed.path {
    Some(path) if path.has_prefix("/") => path
    _ => default_path(url.path)
  }
  guard !parsed.secure || url.is_secure() else { return }
  guard parsed.secure || !(parsed.same_site is Some(NoRestriction)) else {
    return
  }
  guard prefix_allows(parsed, host_only) else { return }
  guard parsed.secure ||
    url.is_secure() ||
    !self.shadows_secure(parsed.name, domain, path) else {
    return
  }
  let entries = match self.domains.get(domain) {
    Some(entries) => entries
    None => []
  }
  let mut creation_ms = now_ms
  let mut sequence = self.next_sequence
  for i, entry in entries {
    // Step 23: the same name, domain, host-only flag and path.
    if entry.cookie.name == parsed.name &&
      entry.cookie.host_only == host_only &&
      entry.cookie.path == path {
      creation_ms = entry.cookie.creation_ms
      sequence = entry.sequence
      entries.remove(i) |> ignore
      self.total -= 1
      break
    }
  }
  let cookie = {
    name: parsed.name,
    value: parsed.value,
    domain,
    host_only,
    path,
    expires_ms: expiry(parsed, now_ms),
    secure: parsed.secure,
    http_only: parsed.http_only,
    same_site: parsed.same_site,
    creation_ms,
    last_access_ms: now_ms,
  }
  if cookie.is_expired(now_ms) {
    // An expired cookie only deletes the one it replaces.
    if entries.is_empty() {
      self.domains.remove(domain)
    }
    return
  }
  if sequence == self.next_sequence {
    self.next_sequence += 1
  }
  entries.push({ cookie, sequence, })
  self.domains.set(domain, entries)
  self.total += 1
  self.enforce_limits(domain)
}

///|
/// RFC 6265bis-22 §5.7 steps 7-10: the cookie's domain and host-only flag, or
/// `None` when the `Domain` attribute is not one `host` may set.
fn CookieJar::cookie_domain(
  self : CookieJar,
  host : String,
  attribute : String?,
) -> (String, Bool)? {
  guard attribute is Some(domain) else { return Some((host, true)) }
  for c in domain {
    guard c.to_int() < 0x80 else { return None }
  }
  let domain = canonical_ip_literal(domain)
  if is_single_label(domain) ||
    (self.is_public_suffix)(domain) ||
    is_ip_host(host) {
    // A public suffix, or any Domain on an IP host, is only accepted as the
    // host itself, and then as host-only.
    if domain == host {
      Some((host, true))
    } else {
      None
    }
  } else if domain_match(host, domain) {
    Some((domain, false))
  } else {
    None
  }
}

///|
/// RFC 6265bis-22 §5.7 steps 20–22: a `__Secure-` cookie must be Secure; a
/// `__Host-` cookie must also be host-only with a `Path` attribute whose
/// value is `/`; a cookie without a name may not have a value that starts
/// with either prefix, which a server would read as a prefixed name.
/// Prefixes match ignoring ASCII case. Step 21 also accepts a `Path` that
/// falls back to a default path of `/`; this does not, as Chromium, which
/// compares the attribute's value, does not.
fn prefix_allows(parsed : SetCookie, host_only : Bool) -> Bool {
  let name = parsed.name.to_lower()
  if name.is_empty() {
    let value = parsed.value.to_lower()
    !value.has_prefix("__secure-") && !value.has_prefix("__host-")
  } else if name.has_prefix("__secure-") {
    parsed.secure
  } else if name.has_prefix("__host-") {
    parsed.secure && host_only && parsed.path == Some("/")
  } else {
    true
  }
}

///|
/// RFC 6265bis-22 §5.7 step 16: whether an insecure cookie would overwrite or
/// shadow a stored Secure cookie of the same name on a related domain and an
/// enclosing path.
fn CookieJar::shadows_secure(
  self : CookieJar,
  name : String,
  domain : String,
  path : String,
) -> Bool {
  for stored, entries in self.domains {
    guard domain_match(domain, stored) || domain_match(stored, domain) else {
      continue
    }
    for entry in entries {
      let cookie = entry.cookie
      if cookie.secure && cookie.name == name && path_match(path, cookie.path) {
        return true
      }
    }
  }
  false
}

///|
/// RFC 6265bis-22 §5.7 step 6: `Max-Age` wins over `Expires`; a nonpositive one
/// expires the cookie at once. Either is cut to `max_lifetime_ms`.
fn expiry(parsed : SetCookie, now_ms : Int64) -> Int64? {
  let latest = now_ms + max_lifetime_ms
  match parsed.max_age {
    Some(seconds) if seconds <= 0L => Some(@int64.MIN_VALUE)
    Some(seconds) =>
      Some(
        if seconds > max_lifetime_ms / 1000L {
          latest
        } else {
          now_ms + seconds * 1000L
        },
      )
    None => parsed.expires_ms.map(expires => expires.min(latest))
  }
}

///|
/// Applies the bounds after a cookie joins `domain`'s entries, in the order
/// RFC 6265bis-22 §5.7 gives for removing excess cookies. `store_at` has
/// already evicted the expired cookies, the first choice; then a domain over
/// its cap loses its cookies that are not Secure, then any of its cookies,
/// and a jar over its cap loses any cookie, the least recently accessed
/// first each time.
fn CookieJar::enforce_limits(self : CookieJar, domain : String) -> Unit {
  while self.domains.get(domain) is Some(entries) &&
        entries.length() > self.max_per_domain {
    self.evict_oldest(only=Some(domain))
  }
  while self.total > self.max_total {
    self.evict_oldest(only=None)
  }
}

///|
/// Removes the least recently accessed cookie of all, or of one domain,
/// where a cookie that is not Secure goes before a Secure one.
fn CookieJar::evict_oldest(self : CookieJar, only~ : String?) -> Unit {
  let mut oldest : (String, Int32, Entry)? = None
  for domain, entries in self.domains {
    if only is Some(only) && only != domain {
      continue
    }
    for i, entry in entries {
      match oldest {
        Some((_, _, best)) if only is Some(_) &&
          entry.cookie.secure != best.cookie.secure =>
          if best.cookie.secure {
            oldest = Some((domain, i, entry))
          }
        Some((_, _, best)) if !accessed_before(entry, best) => ()
        _ => oldest = Some((domain, i, entry))
      }
    }
  }
  if oldest is Some((domain, i, _)) {
    self.remove_at(domain, i)
  }
}

///|
/// Eviction order: earlier last access first, then earlier creation.
fn accessed_before(a : Entry, b : Entry) -> Bool {
  a.cookie.last_access_ms < b.cookie.last_access_ms ||
  (
    a.cookie.last_access_ms == b.cookie.last_access_ms &&
    a.sequence < b.sequence
  )
}

///|
fn CookieJar::remove_at(self : CookieJar, domain : String, i : Int32) -> Unit {
  guard self.domains.get(domain) is Some(entries) else { return }
  entries.remove(i) |> ignore
  self.total -= 1
  if entries.is_empty() {
    self.domains.remove(domain)
  }
}

///|
fn CookieJar::remove_where(self : CookieJar, drop : (Cookie) -> Bool) -> Unit {
  let emptied = []
  for domain, entries in self.domains {
    let before = entries.length()
    entries.retain(entry => !drop(entry.cookie))
    self.total -= before - entries.length()
    if entries.is_empty() {
      emptied.push(domain)
    }
  }
  for domain in emptied {
    self.domains.remove(domain)
  }
}

///|
/// RFC 6265bis-22 §5.8.3 at `now_ms`: the matching cookies' `name=value`
/// pairs, just the value for a cookie without a name, longer paths first,
/// then earlier creation. Expired cookies met on the way are evicted; the
/// ones sent are marked accessed.
fn CookieJar::header_at(
  self : CookieJar,
  url : RequestUrl,
  now_ms : Int64,
) -> String? {
  let secure = url.is_secure()
  let selected : Array[Entry] = []
  let mut expired = false
  for domain in candidate_domains(url.host) {
    guard self.domains.get(domain) is Some(entries) else { continue }
    for entry in entries {
      let cookie = entry.cookie
      if cookie.is_expired(now_ms) {
        expired = true
      } else if (!cookie.host_only || domain == url.host) &&
        path_match(url.path, cookie.path) &&
        (!cookie.secure || secure) {
        selected.push(entry)
      }
    }
  }
  if expired {
    self.remove_where(cookie => cookie.is_expired(now_ms))
  }
  guard !selected.is_empty() else { return None }
  selected.sort_by((a, b) => {
    let by_path = b.cookie.path.length().compare(a.cookie.path.length())
    if by_path != 0 {
      return by_path
    }
    let by_creation = a.cookie.creation_ms.compare(b.cookie.creation_ms)
    if by_creation != 0 {
      by_creation
    } else {
      a.sequence.compare(b.sequence)
    }
  })
  let header = StringBuilder()
  for i, entry in selected {
    entry.cookie = { ..entry.cookie, last_access_ms: now_ms, }
    if i > 0 {
      header.write_string("; ")
    }
    if !entry.cookie.name.is_empty() {
      header.write_string(entry.cookie.name)
      header.write_char('=')
    }
    header.write_string(entry.cookie.value)
  }
  Some(header.to_string())
}
