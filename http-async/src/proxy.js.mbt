///|
// Fetch connects on its own, through the platform's proxy settings if any (a
// browser's, or Node's and Deno's own reading of the environment), and takes
// no proxy from the transport, so the environment is not read. A request on a
// transport given a proxy fails rather than going direct.
fn platform_proxies(
  proxy : String?,
  trust_env~ : Bool,
  lookup : (String) -> String?,
) -> Proxies {
  ignore(trust_env)
  let given = configure_proxies(proxy, trust_env=false, lookup)
  let refuse = (setting : Result[ProxyServer, String]?) => {
    setting.map(_ => {
      Err(
        "a proxy is not supported on JS: fetch uses the platform's proxy settings",
      )
    })
  }
  { http: refuse(given.http), https: refuse(given.https), bypass: [], }
}
