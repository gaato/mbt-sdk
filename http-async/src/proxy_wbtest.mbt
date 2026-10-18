///|
fn describe_server(server : ProxyServer) -> String {
  match server.authorization {
    None => server.origin
    Some(credentials) => server.origin + " (" + credentials + ")"
  }
}

///|
fn describe_setting(setting : Result[ProxyServer, String]?) -> String {
  match setting {
    None => "none"
    Some(Ok(server)) => describe_server(server)
    Some(Err(message)) => "error: " + message
  }
}

///|
/// How `proxies` sends a request to `origin`: its route, the key its
/// connection is parked under, and its request target for path `/p`.
fn describe_route(proxies : Proxies, url : String) -> String {
  let (origin, _) = split_url(url) catch {
    error => return "unexpected: " + @debug.to_string(error)
  }
  let route = proxies.route(origin) catch {
    @http.HttpError::Protocol(message) => return "Protocol: " + message
    error => return "unexpected: " + @debug.to_string(error)
  }
  let how = match route {
    Direct => "direct"
    Forward(server) => "forward to " + describe_server(server)
    Tunnel(server) => "tunnel via " + describe_server(server)
  }
  how +
  " | key " +
  route.key(origin.text) +
  " | target " +
  route.target(origin.text, "/p")
}

///|
fn env_of(pairs : Array[(String, String)]) -> (String) -> String? {
  let map = Map::from_array(pairs)
  name => map.get(name)
}

///|
test "parse_proxy takes http and https proxy URLs with Basic credentials" {
  for
    (text, expected) in [
      ("http://proxy:3128", "http://proxy:3128"),
      ("  http://proxy:3128  ", "http://proxy:3128"),
      ("proxy:3128", "http://proxy:3128"),
      ("http://proxy", "http://proxy:80"),
      ("https://proxy", "https://proxy:443"),
      ("https://proxy:443", "https://proxy:443"),
      ("HTTP://Proxy.Example:3128/ignored/path?q", "http://proxy.example:3128"),
      ("http://[::1]:3128", "http://[::1]:3128"),
      (
        "http://user:pa%20ss@proxy:3128", "http://proxy:3128 (Basic dXNlcjpwYSBzcw==)",
      ),
      ("http://user@proxy:1", "http://proxy:1 (Basic dXNlcjo=)"),
      (
        "http://user:se%40cret@proxy:1", "http://proxy:1 (Basic dXNlcjpzZUBjcmV0)",
      ),
      ("http://user:p%C3%A9@proxy:1", "http://proxy:1 (Basic dXNlcjpww6k=)"),
      (
        "http://user:p%FF@proxy:1", "error: invalid proxy URL: malformed credentials",
      ),
      (
        "socks5://proxy:1080", "error: unsupported proxy scheme socks5: only http and https proxies are supported",
      ),
      ("http:///path", "error: invalid proxy URL: no host"),
    ] {
    assert_eq(
      describe_setting(Some(parse_proxy(text, source="proxy"))),
      expected,
      msg=text,
    )
  }
  // The URL parser's own refusals are named as the setting's.
  assert_true(
    describe_setting(
      Some(parse_proxy("http://proxy:99999", source="HTTPS_PROXY")),
    ).has_prefix("error: invalid HTTPS_PROXY URL: "),
  )
}

///|
test "configure_proxies prefers an explicit proxy, then reads the environment" {
  let env = env_of([
    ("http_proxy", "http://lower:1"),
    ("HTTP_PROXY", "http://upper:1"),
    ("HTTPS_PROXY", "secure:2"),
    ("NO_PROXY", "skip.test"),
  ])
  for
    (proxy, trust_env, lookup, expected) in [
      // An explicit proxy carries every request; NO_PROXY is not read.
      (
        Some("http://u:p@explicit:9"),
        true,
        env,
        (
          "http://explicit:9 (Basic dTpw)", "http://explicit:9 (Basic dTpw)", false,
        ),
      ),
      // Without one, trust_env decides whether the environment is read.
      (None, false, env, ("none", "none", false)),
      (None, true, env, ("http://lower:1", "http://secure:2", true)),
      // Lower case first, upper case when the lower is unset or empty.
      (
        None,
        true,
        env_of([("http_proxy", " "), ("HTTP_PROXY", "http://upper:1")]),
        ("http://upper:1", "none", false),
      ),
      // ALL_PROXY stands in for a scheme without its own.
      (
        None,
        true,
        env_of([("ALL_PROXY", "http://all:3"), ("https_proxy", "https://own:4")]),
        ("http://all:3", "https://own:4", false),
      ),
      (
        None,
        true,
        env_of([("all_proxy", "http://all:3")]),
        ("http://all:3", "http://all:3", false),
      ),
      // In a CGI program, upper-case HTTP_PROXY may come from a request
      // header and is ignored; the lower-case one and the others are not.
      (
        None,
        true,
        env_of([
          ("REQUEST_METHOD", "GET"),
          ("HTTP_PROXY", "http://evil:1"),
          ("HTTPS_PROXY", "http://s:2"),
        ]),
        ("none", "http://s:2", false),
      ),
      (
        None,
        true,
        env_of([("REQUEST_METHOD", "GET"), ("http_proxy", "http://ok:1")]),
        ("http://ok:1", "none", false),
      ),
      (
        None,
        true,
        env_of([
          ("REQUEST_METHOD", "GET"),
          ("HTTP_PROXY", "http://evil:1"),
          ("ALL_PROXY", "http://all:3"),
        ]),
        ("http://all:3", "http://all:3", false),
      ),
      // A setting that cannot be used is kept as its error.
      (
        None,
        true,
        env_of([("HTTPS_PROXY", "socks5://s:1")]),
        (
          "none", "error: unsupported HTTPS_PROXY scheme socks5: only http and https proxies are supported",
          false,
        ),
      ),
    ] {
    let proxies = configure_proxies(proxy, trust_env~, lookup)
    assert_eq(
      (
        describe_setting(proxies.http),
        describe_setting(proxies.https),
        !proxies.bypass.is_empty(),
      ),
      expected,
    )
  }
}

///|
test "each request is routed by its own URL" {
  let proxies = configure_proxies(
    None,
    trust_env=true,
    env_of([
      ("http_proxy", "http://u:p@proxy:3128"),
      ("https_proxy", "http://proxy:3128"),
      ("no_proxy", "internal.test,10.0.0.0/8,[::1]:8443"),
    ]),
  )
  for
    (origin, expected) in [
      (
        "http://api.test", "forward to http://proxy:3128 (Basic dTpw) | key http://api.test via http://proxy:3128 | target http://api.test/p",
      ),
      (
        "http://api.test:8080", "forward to http://proxy:3128 (Basic dTpw) | key http://api.test:8080 via http://proxy:3128 | target http://api.test:8080/p",
      ),
      (
        "https://api.test", "tunnel via http://proxy:3128 | key https://api.test via http://proxy:3128 | target /p",
      ),
      (
        "https://internal.test", "direct | key https://internal.test | target /p",
      ),
      (
        "http://a.internal.test", "direct | key http://a.internal.test | target /p",
      ),
      ("http://10.1.2.3", "direct | key http://10.1.2.3 | target /p"),
      ("https://[::1]:8443", "direct | key https://[::1]:8443 | target /p"),
      (
        "https://[::1]", "tunnel via http://proxy:3128 | key https://[::1] via http://proxy:3128 | target /p",
      ),
    ] {
    assert_eq(describe_route(proxies, origin), expected, msg=origin)
  }
  // Without proxies every request goes direct.
  let none = configure_proxies(None, trust_env=false, env_of([]))
  assert_eq(
    describe_route(none, "https://api.test"),
    "direct | key https://api.test | target /p",
  )
}

///|
test "an unusable proxy setting fails its requests unless NO_PROXY skips it" {
  let proxies = configure_proxies(
    None,
    trust_env=true,
    env_of([("HTTPS_PROXY", "ftp://proxy:21"), ("NO_PROXY", "skip.test")]),
  )
  assert_eq(
    describe_route(proxies, "https://api.test"),
    "Protocol: unsupported HTTPS_PROXY scheme ftp: only http and https proxies are supported",
  )
  assert_eq(
    describe_route(proxies, "https://skip.test"),
    "direct | key https://skip.test | target /p",
  )
  assert_eq(
    describe_route(proxies, "http://api.test"),
    "direct | key http://api.test | target /p",
  )
}

///|
test "connections through different proxies, or none, are kept apart" {
  let a : ProxyServer = { origin: "http://a:1", authorization: None, }
  let b : ProxyServer = { origin: "http://b:1", authorization: None, }
  let keys = [
    Direct.key("https://api.test"),
    Tunnel(a).key("https://api.test"),
    Tunnel(b).key("https://api.test"),
    Forward(a).key("http://api.test"),
    Direct.key("http://api.test"),
  ]
  for i, key in keys {
    for j, other in keys {
      assert_eq(key == other, i == j, msg="\{key} vs \{other}")
    }
  }
}
