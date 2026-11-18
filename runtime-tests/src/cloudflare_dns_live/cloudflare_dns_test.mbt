// Credential-gated, read-only smoke test against the real API. It decodes
// every record of the zone and prints counts or bounded failure diagnostics.
// Run with scripts/live.sh in an environment that supplies both values.

///|
fn format_live_failure(
  operation : String,
  failure : @cloudflare_dns.Failure,
  credentials? : Array[String],
) -> String {
  match failure {
    Decode(error) =>
      @live_diagnostics.response_failure(operation, error, credentials?)
    Http({ head, body, .. }) =>
      @live_diagnostics.format(
        operation,
        "API error",
        status=head.status,
        body~,
        credentials?,
      )
    Transport(error) =>
      @live_diagnostics.format(operation, error.message(), credentials?)
    Validation(parameter~, message~, ..) =>
      @live_diagnostics.format(
        operation,
        "invalid \{parameter}: \{message}",
        credentials?,
      )
    @cloudflare_dns.Failure::.. =>
      @live_diagnostics.format(operation, "request failed", credentials?)
  }
}

///|
fn[T] live_value(
  operation : String,
  result : Result[T, @cloudflare_dns.Failure],
) -> T raise {
  match result {
    Ok(value) => value
    Err(error) => fail(format_live_failure(operation, error))
  }
}

///|
test "live decode diagnostics show bounded UTF-8 with headers and token redacted" {
  let head : @http.ResponseHead = {
    status: 200,
    headers: @http.Headers::of([("set-cookie", "hidden-cookie")]),
  }
  let token = "fixture-token"
  let zone_id = "fixture-zone"
  let failure : @cloudflare_dns.Failure = Decode(
    Deserialization(
      head,
      message="bad field \{token}",
      body=@utf8.encode(
        "日本語 \{token} \{zone_id} " + "x".repeat(1963) + token + "tail",
      ),
    ),
  )
  let message = format_live_failure("get_dns_settings", failure, credentials=[
    "fixture", token, zone_id, "",
  ])
  assert_true(
    message.has_prefix(
      "get_dns_settings: HTTP 200 decode failed: bad field [redacted]\n日本語 [redacted] [redacted] ",
    ),
  )
  assert_true(message.has_suffix("[redacted]…"))
  assert_false(message.contains("tail"))
  assert_false(message.contains("set-cookie"))
  assert_false(message.contains("hidden-cookie"))
  assert_false(message.contains(token))
  assert_false(message.contains(zone_id))
  assert_false(message.contains("fixture"))
}

///|
test "live decode diagnostic truncation keeps Unicode character boundaries" {
  for (offset, suffix) in [(1997, "😀…"), (1998, "…"), (1999, "…")] {
    let prefix = "x".repeat(offset)
    let body = @utf8.encode(prefix + "😀rest")
    let diagnostic = @live_diagnostics.format("operation", "failed", body~)
    assert_eq(diagnostic, "operation: failed\n" + prefix + suffix)
    assert_eq(@utf8.decode(@utf8.encode(diagnostic)), diagnostic)
  }
  let exact = "x".repeat(1998) + "😀"
  let diagnostic = @live_diagnostics.format(
    "operation",
    "failed",
    body=@utf8.encode(exact),
  )
  assert_eq(diagnostic, "operation: failed\n" + exact)
}

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
    let zones = live_value("list_zones", sdk.list_zones(per_page=5))
    println("list_zones: \{zones.length()} zone(s) visible to the token")
    ignore(live_value("get_zone", sdk.get_zone(zone_id~)))
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
    live_value("list_dns_records_pages", walked)
    println("records by type: " + @debug.to_string(counts))
    ignore(live_value("get_dnssec", sdk.get_dnssec(zone_id~)))
    ignore(live_value("get_dns_settings", sdk.get_dns_settings(zone_id~)))
    let text = live_value(
      "export_dns_records",
      sdk.export_dns_records(zone_id~),
    )
    println("export_dns_records: \{text.length()} characters of BIND text")
  })
}
