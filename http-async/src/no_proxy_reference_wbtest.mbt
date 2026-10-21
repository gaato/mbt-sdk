// The NO_PROXY tables of two reference implementations, ported by hand. See
// NOTICE for their licenses.

///|
test "NO_PROXY agrees with Go's httpproxy table" {
  // golang.org/x/net/http/httpproxy proxy_test.go at 4af4fce62e93:
  // `noProxy` and `UseProxyTests`, every host on port 80. Go's `match` is
  // "use the proxy"; `expected` here is the opposite, "bypass it". Go never
  // proxies `localhost` and loopback addresses whatever NO_PROXY says; that
  // is a rule of its own, not of the list, so those rows are left out.
  let no_proxy = "foobar.com, .barbaz.net, *.wildcard.io, 192.168.1.1, 192.168.1.2:81, 192.168.1.3:80, 10.0.0.0/30, 2001:db8::52:0:1, [2001:db8::52:0:2]:443, [2001:db8::52:0:3]:80, 2002:db8:a::45/64"
  let rules = parse_no_proxy(no_proxy)
  for
    (host, expected) in [
      ("::2", false),
      ("192.168.1.1", true),
      ("192.168.1.2", false),
      ("192.168.1.3", true),
      ("192.168.1.4", false),
      ("10.0.0.2", true),
      ("2001:db8::52:0:1", true),
      ("2001:db8::52:0:2", false),
      ("2001:db8::52:0:3", true),
      ("2002:db8:a::123", true),
      ("fe80::424b:c8be:1643:a1b6", false),
      // Go: `.barbaz.net` and `*.wildcard.io` cover only subdomains. curl,
      // which this follows, drops the leading dot, so the domain itself is
      // covered too.
      ("barbaz.net", true),
      ("www.barbaz.net", true),
      ("foobar.com", true),
      ("www.foobar.com", true),
      ("foofoobar.com", false),
      ("baz.com", false),
      ("localhost.net", false),
      ("local.localhost", false),
      ("barbarbaz.net", false),
      ("wildcard.io", true),
      ("nested.wildcard.io", true),
      ("awildcard.io", false),
    ] {
    assert_eq(bypasses_proxy(rules, host, 80), expected, msg=host)
  }
  // TestInvalidNoProxy: an entry that is only a port bypasses nothing.
  assert_eq(bypasses_proxy(parse_no_proxy(":1"), "example.com", 80), false)
}

///|
test "NO_PROXY agrees with curl's noproxy table" {
  // curl tests/unit/unit1614.c at 6e57ed116607: the `list` table, run through
  // `proxy_check_noproxy`. Hosts are given as a canonical origin spells them,
  // lower-case and IPv6 without brackets, as `bypasses_proxy` expects.
  let long_address = "localhost,127.0.0.1.127.0.0.1.127.0.0.1.127.0.0.1.127.0.0.1.127.0.0.1.127.0.0.1.127.0.0.1.127.0.0.1.127.0.0.1.127.0.0.1.127.0.0.1.127.0.0."
  for
    (host, no_proxy, expected) in [
      ("www.example.com", "localhost .example.com .example.de", false),
      ("www.example.com", "localhost,.example.com,.example.de", true),
      ("www.example.com.", "localhost,.example.com,.example.de", true),
      ("example.com", "localhost,.example.com,.example.de", true),
      ("example.com.", "localhost,.example.com,.example.de", true),
      ("www.example.com", "localhost,.example.com.,.example.de", true),
      ("www.example.com", "localhost,www.example.com.,.example.de", true),
      ("example.com", "localhost,example.com,.example.de", true),
      ("example.com.", "localhost,example.com,.example.de", true),
      ("nexample.com", "localhost,example.com,.example.de", false),
      ("www.example.com", "localhost,example.com,.example.de", true),
      ("127.0.0.1", "127.0.0.1,localhost", true),
      ("127.0.0.1", "127.0.0.1,localhost,", true),
      ("127.0.0.1", "127.0.0.1/8,localhost,", true),
      ("127.0.0.1", "127.0.0.1/28,localhost,", true),
      ("127.0.0.1", "127.0.0.1/31,localhost,", true),
      ("127.0.0.1", "localhost,127.0.0.1", true),
      ("127.0.0.1", long_address, false),
      ("127.0.0.1", long_address[:long_address.length() - 1].to_owned(), false),
      ("localhost", "localhost,127.0.0.1", true),
      ("localhost", "127.0.0.1,localhost", true),
      ("foobar", "barfoo", false),
      ("foobar", "foobar", true),
      ("192.168.0.1", "foobar", false),
      ("192.168.0.1", "192.168.0.0/16", true),
      ("192.168.0.1", "192.168.0.0/16a", false),
      ("192.168.0.1", "192.168.0.0/16 ", true),
      ("192.168.0.1", "192.168.0.0/a16", false),
      ("192.168.0.1", "192.168.0.0/ 16", false),
      ("192.168.0.1", "192.168.0.0/24", true),
      ("192.168.0.1", "192.168.0.0/32", false),
      ("192.168.0.1", "192.168.0.1/32", true),
      ("192.168.0.1", "192.168.0.1/33", false),
      ("192.168.0.1", "192.168.0.0", false),
      ("192.168.1.1", "192.168.0.0/24", false),
      ("192.168.1.1", "192.168.0.0/33", false),
      ("192.168.1.1", "foo, bar, 192.168.0.0/24", false),
      ("192.168.1.1", "foo, bar, 192.168.0.0/16", true),
      ("192.168.1.1", "0.0.0.0/0", true),
      ("192.168.1.1", "0.0.0.0", false),
      ("::1", "::/0", true),
      ("::1", "::", false),
      ("::1", "::/128", false),
      ("::1", "foo, bar, 192.168.0.0/16", false),
      ("::1", "foo, bar, ::1/64", true),
      ("::1", "::1/64", true),
      ("::1", "::1/96", true),
      ("::1", "::1/129", false),
      ("::1", "::1/128", true),
      ("::1", "::1/127", true),
      ("::1", "::1/a127", false),
      ("::1", "::1/127a", false),
      ("::1", "::1/ 127", false),
      ("::1", "::1/127 ", true),
      ("::1", "::1/126", true),
      ("::1", "::1/125", true),
      ("::1", "::1/124", true),
      ("::1", "::1/123", true),
      ("::1", "::1/122", true),
      ("2001:db8:8000::1", "2001:db8::/65", false),
      ("2001:db8:8000::1", "2001:db8::/66", false),
      ("2001:db8:8000::1", "2001:db8::/67", false),
      ("2001:db8:8000::1", "2001:db8::/68", false),
      ("2001:db8:8000::1", "2001:db8::/69", false),
      ("2001:db8:8000::1", "2001:db8::/70", false),
      ("2001:db8:8000::1", "2001:db8::/71", false),
      ("2001:db8:8000::1", "2001:db8::/72", false),
      ("2001:db8::1", "2001:db8::/65", true),
      ("2001:db8::1", "2001:db8::/66", true),
      ("2001:db8::1", "2001:db8::/67", true),
      ("2001:db8::1", "2001:db8::/68", true),
      ("2001:db8::1", "2001:db8::/69", true),
      ("2001:db8::1", "2001:db8::/70", true),
      ("2001:db8::1", "2001:db8::/71", true),
      ("2001:db8::1", "2001:db8::/72", true),
      ("bar", "foo, bar, ::1/64", true),
      ("bar", "foo,,,,,              bar, ::1/64", true),
      ("www.example.com", "foo, .example.com", true),
      ("www.example.com", "www2.example.com, .example.net", false),
      ("example.com", ".example.com, .example.net", true),
      ("nonexample.com", ".example.com, .example.net", false),
    ] {
    assert_eq(
      bypasses_proxy(parse_no_proxy(no_proxy), host, 80),
      expected,
      msg="NO_PROXY=\{no_proxy} \{host}",
    )
  }
}
