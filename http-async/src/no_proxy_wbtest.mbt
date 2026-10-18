///|
test "bypasses_proxy reads NO_PROXY as curl does" {
  for
    (no_proxy, host, port, expected) in [
      // `*` alone, or as any entry, matches every host.
      ("*", "example.com", 443, true),
      ("a.test, *", "::1", 80, true),
      ("", "example.com", 443, false),
      // A name matches itself and its subdomains, never a longer label.
      ("example.com", "example.com", 443, true),
      ("example.com", "api.example.com", 443, true),
      ("example.com", "a.b.example.com", 80, true),
      ("example.com", "notexample.com", 443, false),
      ("example.com", "example.com.evil", 443, false),
      // A leading dot is dropped, as curl and requests do; trailing dots and
      // case do not matter.
      (".example.com", "example.com", 80, true),
      (".example.com", "api.example.com", 80, true),
      ("EXAMPLE.com.", "example.com", 80, true),
      ("example.com", "example.com.", 80, true),
      // A port restricts the entry to it.
      ("example.com:8080", "example.com", 8080, true),
      ("example.com:8080", "api.example.com", 8080, true),
      ("example.com:8080", "example.com", 443, false),
      // Names are never resolved.
      ("localhost", "localhost", 80, true),
      ("localhost", "127.0.0.1", 80, false),
      ("example.com", "93.184.216.34", 443, false),
      // IPv4 addresses and networks.
      ("127.0.0.1", "127.0.0.1", 80, true),
      ("127.0.0.1", "127.0.0.2", 80, false),
      ("127.0.0.1:80", "127.0.0.1", 81, false),
      ("10.0.0.0/8", "10.20.30.40", 443, true),
      ("10.0.0.0/8", "11.0.0.1", 443, false),
      ("10.1.2.3/20", "10.1.15.255", 443, true),
      ("10.1.2.3/20", "10.1.16.0", 443, false),
      ("0.0.0.0/0", "203.0.113.9", 443, true),
      ("0.0.0.0/0", "::1", 443, false),
      // IPv6, bare or bracketed, with a port only in brackets.
      ("::1", "::1", 80, true),
      ("[::1]", "::1", 80, true),
      ("0:0:0:0:0:0:0:1", "::1", 80, true),
      ("[::1]:8080", "::1", 8080, true),
      ("[::1]:8080", "::1", 80, false),
      ("fd00::/8", "fd12:3456::1", 443, true),
      ("FD00:0:0:0:0:0:0:AbC/128", "fd00::abc", 443, true),
      ("[fd00::/8]", "fd12:3456::1", 443, true),
      ("2001:db8::/32", "2001:db9::1", 443, false),
      ("::ffff:10.0.0.1", "::ffff:a00:1", 443, true),
      ("::/0", "127.0.0.1", 443, false),
      // Spaces around entries and empty entries are ignored.
      (" a.test ,, b.test ", "b.test", 443, true),
      // Malformed entries are skipped, so they bypass nothing.
      ("bad entry!, b.test", "b.test", 443, true),
      ("bad entry!", "bad entry!", 443, false),
      ("10.0.0.0/33", "10.0.0.1", 443, false),
      ("10.0.0.0/", "10.0.0.1", 443, false),
      ("10.0.0.0/x", "10.0.0.1", 443, false),
      ("example.com:0", "example.com", 443, false),
      ("example.com:http", "example.com", 80, false),
      ("[::1", "::1", 80, false),
      ("[::1]x", "::1", 80, false),
      ("[::1]:0", "::1", 80, false),
      ("1::2::3", "1::2:0:3", 80, false),
      ("1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8", 80, false),
      ("1:2:3:4:5:6:7:8::", "1:2:3:4:5:6:7:8", 80, false),
      ("12345::1", "::1", 80, false),
      ("::1.2.3", "::1", 80, false),
      ("1.2.3.256", "1.2.3.0", 80, false),
      ("1.2..3", "1.2.0.3", 80, false),
      (".", "example.com", 80, false),
    ] {
    assert_eq(
      bypasses_proxy(parse_no_proxy(no_proxy), host, port),
      expected,
      msg="NO_PROXY=\{no_proxy} \{host}:\{port}",
    )
  }
}

///|
test "a NO_PROXY list bypasses what any of its entries bypasses" {
  // Joining entries never changes what each one matches.
  let entries = [
    "example.com", ".api.test", "10.0.0.0/8", "[::1]:8080", "192.0.2.7", "fd00::/8",
    "intranet:81", "bad entry!",
  ]
  let hosts = [
    ("example.com", 443),
    ("www.api.test", 80),
    ("10.9.8.7", 443),
    ("::1", 8080),
    ("::1", 80),
    ("192.0.2.7", 80),
    ("fd00::5", 443),
    ("intranet", 81),
    ("intranet", 80),
    ("other.test", 443),
  ]
  let rand = @random.Rand::chacha8(seed=b"no_proxy composition seed 32byte")
  for _ in 0..<200 {
    let chosen = entries.filter(_ => rand.int(limit=2) == 0)
    let joined = chosen.join(if rand.int(limit=2) == 0 { "," } else { " , " })
    for target in hosts {
      let (host, port) = target
      assert_eq(
        bypasses_proxy(parse_no_proxy(joined), host, port),
        chosen.any(entry => bypasses_proxy(parse_no_proxy(entry), host, port)),
        msg="NO_PROXY=\{joined} \{host}:\{port}",
      )
    }
  }
}
