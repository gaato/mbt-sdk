///|
test "URL encoding matches generated helpers" {
  assert_eq(@http.percent_encode("a b/c~é"), "a%20b%2Fc~%C3%A9")
  assert_eq(@http.percent_encode_path("a b/c~é"), "a%20b/c~%C3%A9")
  assert_eq(@http.percent_encode(""), "")
  assert_eq(@http.percent_encode_path(""), "")
  assert_eq(@http.percent_encode("AZaz09-._~%?#"), "AZaz09-._~%25%3F%23")
  assert_eq(@http.append_query("/p", "a b", "é/"), "/p?a%20b=%C3%A9%2F")
  assert_eq(@http.append_query("/p?x=1", "", ""), "/p?x=1&=")
  assert_eq(@http.append_query("/p?", "a", "b"), "/p?&a=b")
}
