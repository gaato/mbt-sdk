// Credential-gated, read-only smoke test against the real API. It decodes
// every record of the zone (the record union's real-world coverage) and prints
// only counts and failure values, never the token. Run this package explicitly
// in an environment that supplies both values.

///|
async test "live Cloudflare DNS and Zones read-only" {
  guard @env.get_env_var("CLOUDFLARE_API_TOKEN").map(value => {
      value.trim().to_owned()
    })
    is Some(token) &&
    @env.get_env_var("CLOUDFLARE_ZONE_ID").map(value => value.trim().to_owned())
    is Some(zone_id) &&
    token != "" &&
    zone_id != "" else {
    println("skip: set CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID")
    return
  }
  @async.with_task_group(group => {
    let backend = @codings.Decompress::new(@backend.AsyncBackend::new())
    defer backend.close()
    let sdk = @cloudflare_dns.CloudflareDns::new(
      backend,
      @adapter.AsyncClock::new(),
      auth=ApiToken(token),
    )
    ignore(group)
    let zones = sdk.list_zones(per_page=5)
    guard zones is Ok(zones) else {
      fail("list_zones: " + @debug.to_string(zones))
    }
    println("list_zones: \{zones.length()} zone(s) visible to the token")
    let zone = sdk.get_zone(zone_id~)
    guard zone is Ok(_) else { fail("get_zone: " + @debug.to_string(zone)) }
    // Small pages so the paginator walks several pages on most zones.
    let counts : Map[String, Int32] = Map([])
    let walked = sdk
      .list_dns_records_pages(zone_id~, per_page=5)
      .each(record => {
        let kind = match record {
          Unknown(kind, _) => "Unknown(" + kind + ")"
          _ =>
            match @debug.to_string(record).split("(").next() {
              Some(name) => name.to_owned()
              None => "?"
            }
        }
        counts[kind] = counts.get(kind).unwrap_or(0) + 1
        Ok(())
      })
    guard walked is Ok(_) else {
      fail("list_dns_records_pages: " + @debug.to_string(walked))
    }
    println("records by type: " + @debug.to_string(counts))
    let dnssec = sdk.get_dnssec(zone_id~)
    guard dnssec is Ok(_) else {
      fail("get_dnssec: " + @debug.to_string(dnssec))
    }
    let settings = sdk.get_dns_settings(zone_id~)
    guard settings is Ok(_) else {
      fail("get_dns_settings: " + @debug.to_string(settings))
    }
    let exported = sdk.export_dns_records(zone_id~)
    guard exported is Ok(text) else {
      fail("export_dns_records: " + @debug.to_string(exported))
    }
    println("export_dns_records: \{text.length()} characters of BIND text")
  })
}
