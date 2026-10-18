///|
test "is_ip_host recognises IP literals by the ends-in-a-number rule" {
  let cases = [
    ("127.0.0.1", true),
    ("10.0.0.1.", true),
    ("127.1", true),
    ("0x7f.1", true),
    ("1.0x", true),
    ("[::1]", true),
    ("[2001:db8::1]", true),
    ("example.com", false),
    ("example.com.", false),
    ("1.example", false),
    ("localhost", false),
    ("0xzz", false),
    ("a1", false),
    (".", false),
  ]
  for case in cases {
    assert_eq(is_ip_host(case.0), case.1, msg=case.0)
  }
}

///|
test "domain_match follows RFC 6265 section 5.1.3" {
  let cases = [
    ("example.com", "example.com", true),
    ("www.example.com", "example.com", true),
    ("a.b.example.com", "example.com", true),
    ("a.b.example.com", "b.example.com", true),
    ("example.com", "www.example.com", false),
    ("badexample.com", "example.com", false),
    ("example.com", "com", true),
    ("example.com", ".example.com", false),
    ("127.0.0.1", "127.0.0.1", true),
    ("127.0.0.1", "0.0.1", false),
    ("10.0.0.1", "0.1", false),
    ("[::1]", "[::1]", true),
  ]
  for case in cases {
    assert_eq(domain_match(case.0, case.1), case.2, msg="\{case.0} ~ \{case.1}")
  }
}

///|
test "candidate_domains lists the host and its parents, not an IP's" {
  assert_eq(candidate_domains("a.b.example.com"), [
    "a.b.example.com", "b.example.com", "example.com", "com",
  ])
  assert_eq(candidate_domains("localhost"), ["localhost"])
  assert_eq(candidate_domains("192.168.0.1"), ["192.168.0.1"])
  assert_eq(candidate_domains("[::1]"), ["[::1]"])
  assert_eq(candidate_domains("example.com."), ["example.com.", "com."])
}

///|
test "single labels are the public suffixes known without a list" {
  assert_true(is_single_label("com"))
  assert_true(is_single_label("localhost"))
  assert_true(is_single_label("[::1]"))
  assert_false(is_single_label("example.com"))
  assert_false(is_single_label("co.uk"))
}
