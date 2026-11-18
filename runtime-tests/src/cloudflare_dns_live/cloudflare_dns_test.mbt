// Credential-gated, read-only smoke test against the real API. It decodes
// every record of the zone and prints counts or bounded failure diagnostics.
// Run this package explicitly in an environment that supplies both values.

///|
fn format_live_failure(
  operation : String,
  failure : @cloudflare_dns.Failure,
  token : String,
) -> String {
  let details = match failure {
    Decode(Deserialization(_, message~, body~)) => {
      let message = message.replace_all(old=token, new="[redacted]")
      let body = @utf8.decode_lossy(body).replace_all(
        old=token,
        new="[redacted]",
      )
      let preview = if body.length() > 2000 {
        body[:2000].to_owned() + "…"
      } else {
        body
      }
      return "\{operation} decode failed\n\{message}\n\{preview}"
    }
    Decode(UnexpectedStatus(head, ..)) => "unexpected HTTP \{head.status}"
    Decode(_) => "response decoding failed"
    Http(error) => "HTTP \{error.head.status}"
    Transport(error) => error.message()
    Validation(parameter~, message~, ..) => "invalid \{parameter}\n\{message}"
    @cloudflare_dns.Failure::.. => "request failed"
  }
  let details = details.replace_all(old=token, new="[redacted]")
  "\{operation} \{details}"
}

///|
fn[T] live_value(
  operation : String,
  result : Result[T, @cloudflare_dns.Failure],
  token : String,
) -> T raise {
  match result {
    Ok(value) => value
    Err(error) => fail(format_live_failure(operation, error, token))
  }
}

///|
test "live decode diagnostics show bounded UTF-8 with headers and token redacted" {
  let head : @http.ResponseHead = {
    status: 200,
    headers: @http.Headers::of([("set-cookie", "hidden-cookie")]),
  }
  let token = "fixture-token"
  let failure : @cloudflare_dns.Failure = Decode(
    Deserialization(
      head,
      message="bad field \{token}",
      body=@utf8.encode("日本語 \{token} " + "x".repeat(2000) + "tail"),
    ),
  )
  let message = format_live_failure("get_dns_settings", failure, token)
  assert_true(
    message.has_prefix(
      "get_dns_settings decode failed\nbad field [redacted]\n日本語 [redacted] ",
    ),
  )
  assert_true(message.has_suffix("…"))
  assert_false(message.contains("tail"))
  assert_false(message.contains("set-cookie"))
  assert_false(message.contains("hidden-cookie"))
  assert_false(message.contains(token))
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
    let zones = live_value("list_zones", sdk.list_zones(per_page=5), token)
    println("list_zones: \{zones.length()} zone(s) visible to the token")
    ignore(live_value("get_zone", sdk.get_zone(zone_id~), token))
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
    live_value("list_dns_records_pages", walked, token)
    println("records by type: " + @debug.to_string(counts))
    ignore(live_value("get_dnssec", sdk.get_dnssec(zone_id~), token))
    ignore(
      live_value("get_dns_settings", sdk.get_dns_settings(zone_id~), token),
    )
    let text = live_value(
      "export_dns_records",
      sdk.export_dns_records(zone_id~),
      token,
    )
    println("export_dns_records: \{text.length()} characters of BIND text")
  })
}
