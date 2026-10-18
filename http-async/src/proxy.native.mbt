///|
// Native and Wasm dial their own connections, so the transport routes them
// through the proxy it is given, or those the environment names.
fn platform_proxies(
  proxy : String?,
  trust_env~ : Bool,
  lookup : (String) -> String?,
) -> Proxies {
  configure_proxies(proxy, trust_env~, lookup)
}
