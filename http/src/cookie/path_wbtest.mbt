///|
test "default_path follows RFC 6265 section 5.1.4" {
  let cases = [
    ("", "/"),
    ("/", "/"),
    ("foo", "/"),
    ("/foo", "/"),
    ("/foo/", "/foo"),
    ("/foo/bar", "/foo"),
    ("/foo/bar/", "/foo/bar"),
    ("//", "/"),
    ("/a//b", "/a/"),
  ]
  for case in cases {
    assert_eq(default_path(case.0), case.1, msg=case.0)
  }
}

///|
test "path_match follows RFC 6265 section 5.1.4" {
  let cases = [
    ("/", "/", true),
    ("/foo", "/", true),
    ("/foo", "/foo", true),
    ("/foo/", "/foo", true),
    ("/foo/bar", "/foo", true),
    ("/foo/bar", "/foo/", true),
    ("/foobar", "/foo", false),
    ("/fo", "/foo", false),
    ("/", "/foo", false),
    ("/FOO", "/foo", false),
    ("/foo/bar", "/bar", false),
  ]
  for case in cases {
    assert_eq(path_match(case.0, case.1), case.2, msg="\{case.0} ~ \{case.1}")
  }
}
