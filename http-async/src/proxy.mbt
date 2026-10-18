///|
/// A proxy server: where to dial, and what to tell it.
priv struct ProxyServer {
  /// `http://host:port` or `https://host:port`, the port always written.
  origin : String
  /// `Basic` credentials from the proxy URL's userinfo, for the
  /// `Proxy-Authorization` header. They go to the proxy alone.
  authorization : String?
}

///|
/// How a request reaches its origin.
priv enum Route {
  Direct
  /// An `http://` request handed to the proxy, its target in absolute form
  /// (RFC 9112 §3.2.2), on a connection to the proxy.
  Forward(ProxyServer)
  /// An `https://` request sent through a tunnel the proxy opens with
  /// `CONNECT` (RFC 9110 §9.3.6), TLS running end to end inside it.
  Tunnel(ProxyServer)
}

///|
/// The proxies a transport uses, fixed when it is made: one for `http://`
/// requests and one for `https://`, each a server or why the setting
/// cannot be used, and the hosts that skip them. A request whose proxy
/// setting is unusable fails rather than going direct.
priv struct Proxies {
  http : Result[ProxyServer, String]?
  https : Result[ProxyServer, String]?
  bypass : Array[NoProxyRule]
}

///|
/// The proxies for an explicit `proxy` URL, which carries every request
/// (httpx's `proxy=`), or else, when `trust_env`, those the environment
/// names through `lookup`, as curl and httpx read it:
/// - `http_proxy` for `http://` requests, `https_proxy` for `https://`,
///   `all_proxy` for either when its own is unset;
/// - `no_proxy` for the hosts that go direct (`parse_no_proxy`);
/// - each name in lower case first, then upper case; an empty value is
///   unset. Upper-case `HTTP_PROXY` is ignored when `REQUEST_METHOD` is
///   set, since a CGI program gets it from a request's `Proxy` header
///   (httpoxy, CVE-2016-5385), as Go and Python ignore it.
fn configure_proxies(
  proxy : String?,
  trust_env~ : Bool,
  lookup : (String) -> String?,
) -> Proxies {
  if proxy is Some(text) {
    let server = Some(parse_proxy(text, source="proxy"))
    return { http: server, https: server, bypass: [], }
  }
  guard trust_env else { return { http: None, https: None, bypass: [], } }
  let cgi = lookup("REQUEST_METHOD") is Some(value) && !value.is_empty()
  let all = env_value(lookup, "all_proxy", upper=true)
  let setting = (own : (String, String)?) => {
    guard (if own is Some(_) { own } else { all }) is Some((name, value)) else {
      None
    }
    Some(parse_proxy(value, source=name))
  }
  {
    http: setting(env_value(lookup, "http_proxy", upper=!cgi)),
    https: setting(env_value(lookup, "https_proxy", upper=true)),
    bypass: match env_value(lookup, "no_proxy", upper=true) {
      Some((_, value)) => parse_no_proxy(value)
      None => []
    },
  }
}

///|
/// The first non-empty of `name` and, when `upper`, its upper-case form,
/// with the spelling found.
fn env_value(
  lookup : (String) -> String?,
  name : String,
  upper~ : Bool,
) -> (String, String)? {
  let names = if upper { [name, name.to_upper()] } else { [name] }
  for candidate in names {
    if lookup(candidate) is Some(value) && !value.trim().is_empty() {
      return Some((candidate, value.trim().to_owned()))
    }
  }
  None
}

///|
/// The proxy at `text`: `http://` or `https://`, a scheme taken as `http://`
/// when missing (curl, httpx's environment), the port as the scheme's
/// default when missing, and `user:password@` percent-decoded into `Basic`
/// credentials. A path is ignored. `source` names the setting in the error.
fn parse_proxy(text : String, source~ : String) -> Result[ProxyServer, String] {
  let text = text.trim().to_owned()
  let text = if text.contains("://") { text } else { "http://" + text }
  let url = @http.Url::parse(text) catch {
    @http.UrlError::Invalid(reason) =>
      return Err("invalid \{source} URL: \{reason}")
  }
  let scheme = url.scheme.unwrap_or("")
  guard scheme is ("http" | "https") else {
    return Err(
      "unsupported \{source} scheme \{scheme}: only http and https proxies are supported",
    )
  }
  guard url.host is Some(host) && !host.is_empty() else {
    return Err("invalid \{source} URL: no host")
  }
  let authorization = match url.userinfo {
    None => None
    Some(userinfo) =>
      match basic_credentials(userinfo) {
        Some(credentials) => Some(credentials)
        None => return Err("invalid \{source} URL: malformed credentials")
      }
  }
  let host = if host.contains(":") { "[" + host + "]" } else { host }
  let port = url.port_or_default().unwrap_or(80)
  Ok({ origin: "\{scheme}://\{host}:\{port}", authorization, })
}

///|
/// `Basic` credentials (RFC 7617) for a URL's userinfo, its user and
/// password percent-decoded; a userinfo without `:` is a user with an empty
/// password, as httpx takes it.
fn basic_credentials(userinfo : String) -> String? {
  let (user, password) = match userinfo.find(":") {
    Some(colon) => (userinfo[:colon], userinfo[colon + 1:])
    None => (userinfo[:], "")
  }
  let user = @percent.decode(user) catch { _ => return None }
  let password = @percent.decode(password) catch { _ => return None }
  Some("Basic " + @base64.encode(@http.encode_utf8(user + ":" + password)))
}

///|
/// The route of a request to `origin`: direct when its scheme has no proxy
/// or `bypass` names its host, otherwise forwarded (`http://`) or tunnelled
/// (`https://`). A request is routed by its own URL, so a redirect to another
/// origin is routed afresh. An unusable proxy setting raises `Protocol`
/// before anything is sent.
fn Proxies::route(
  self : Proxies,
  origin : Origin,
) -> Route raise @http.HttpError {
  guard (if origin.https { self.https } else { self.http }) is Some(setting) else {
    return Direct
  }
  if bypasses_proxy(self.bypass, origin.host, origin.port) {
    return Direct
  }
  match setting {
    Ok(server) => if origin.https { Tunnel(server) } else { Forward(server) }
    Err(message) => raise @http.HttpError::Protocol(message)
  }
}

///|
/// The key that parks and counts connections for `origin` on this route: a
/// connection to the proxy or through its tunnel is never handed to a
/// request that goes direct, or through another proxy.
fn Route::key(self : Route, origin : String) -> String {
  match self {
    Direct => origin
    Forward(server) | Tunnel(server) => origin + " via " + server.origin
  }
}

///|
/// The request target: `path` on the origin's own connection or tunnel,
/// the absolute URL when the proxy forwards the request.
fn Route::target(self : Route, origin : String, path : String) -> String {
  match self {
    Forward(_) => origin + path
    Direct | Tunnel(_) => path
  }
}

///|
/// Opens a connection to `origin` on `route`: to the origin itself, to the
/// proxy, or to the proxy and then, through a `CONNECT` tunnel, to the
/// origin, whose TLS runs inside it. `Proxy-Authorization` goes on the
/// proxy's connection alone, so the origin never sees it. moonbitlang/async
/// sends the `CONNECT` and refuses a non-2xx answer with `ProxyError`, which
/// `failure` makes `HttpError::Proxy`. It also names the dialed proxy in
/// `Host`, for a forwarded request too; RFC 9112 §3.2.2 has a proxy take the
/// target from the absolute form and replace `Host`.
async fn dial(
  origin : String,
  route : Route,
  user_agent : String?,
) -> @ahttp.Client {
  let headers : @ahttp.Headers = Map([])
  if user_agent is Some(value) {
    headers["User-Agent"] = value
  }
  match route {
    Direct => @ahttp.Client(origin, headers~)
    Forward(server) =>
      @ahttp.Client(server.origin, headers=proxy_headers(server, user_agent))
    Tunnel(server) => {
      let proxy = @ahttp.Client(
        server.origin,
        headers=proxy_headers(server, user_agent),
      )
      // The tunnel owns `proxy` once made; closing is idempotent.
      errdefer proxy.close()
      @ahttp.Client(origin, headers~, proxy~)
    }
  }
}

///|
fn proxy_headers(server : ProxyServer, user_agent : String?) -> @ahttp.Headers {
  let headers : @ahttp.Headers = Map([])
  if user_agent is Some(value) {
    headers["User-Agent"] = value
  }
  if server.authorization is Some(credentials) {
    headers["Proxy-Authorization"] = credentials
  }
  headers
}
