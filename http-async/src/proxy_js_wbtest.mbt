///|
test "on JS a given proxy refuses its requests and the environment is unread" {
  let read = []
  let lookup = (name : String) => {
    read.push(name)
    Some("http://env:1")
  }
  let refused = platform_proxies(
    Some("http://explicit:9"),
    trust_env=true,
    lookup,
  )
  assert_eq(
    describe_route(refused, "https://api.test"),
    "Protocol: a proxy is not supported on JS: fetch uses the platform's proxy settings",
  )
  assert_eq(
    describe_route(refused, "http://api.test"),
    "Protocol: a proxy is not supported on JS: fetch uses the platform's proxy settings",
  )
  let from_env = platform_proxies(None, trust_env=true, lookup)
  assert_eq(
    describe_route(from_env, "https://api.test"),
    "direct | key https://api.test | target /p",
  )
  assert_eq(read, [])
}
