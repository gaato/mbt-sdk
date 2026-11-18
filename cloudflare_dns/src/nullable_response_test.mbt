///|
test "DNS settings decode the live response with null SOA and internal DNS fields" {
  // Cloudflare live response captured 2026-11-18. Zone and token were not
  // recorded. The fixture contains only the response body.
  let body =
    #|{"result":{"nameservers":{"type":"cloudflare.standard"},"foundation_dns":false,"multi_provider":false,"secondary_overrides":false,"soa":{"mname":null,"rname":"dns.cloudflare.com","refresh":10000,"retry":2400,"expire":604800,"min_ttl":1800,"ttl":3600},"ns_ttl":86400,"zone_mode":"standard","internal_dns":{"reference_zone_id":null},"flatten_all_cnames":false},"success":true,"errors":[],"messages":[]}
    #|
  let backend = @client.from_fn((_, _) => {
    @http.Response::new(
      200,
      headers=@http.Headers::of([("content-type", "application/json")]),
      body=Bytes(@utf8.encode(body)),
    )
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    let result = sdk.get_dns_settings(zone_id="zone")
    guard result is Ok(settings) else { fail(@debug.to_string(result)) }
    assert_true(settings.internal_dns.reference_zone_id is None)
    assert_true(Json(settings.soa) is { "mname": Null, .. })
    assert_true(settings.soa.ttl is Some(3600))
  })
}

///|
test "DNS settings accept omitted SOA and internal DNS fields" {
  let backend = @client.from_fn((_, _) => {
    json_reply({
      "success": true,
      "result": {
        "flatten_all_cnames": false,
        "foundation_dns": false,
        "internal_dns": {},
        "multi_provider": false,
        "nameservers": { "type": "cloudflare.standard" },
        "ns_ttl": 86400,
        "secondary_overrides": false,
        "soa": { "refresh": Json::null(), "rname": Json::null() },
        "zone_mode": "standard",
      },
    })
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    let result = sdk.get_dns_settings(zone_id="zone")
    guard result is Ok(settings) else { fail(@debug.to_string(result)) }
    assert_true(Json(settings.internal_dns) is { })
    assert_true(Json(settings.soa) is { })
  })
}

///|
test "zone replies can omit activation and original DNS fields" {
  let fixture = zone_fixture("zone")
  guard fixture is Object(fields) else { fail("expected a zone object") }
  let fields = fields.copy()
  for
    field in [
      "activated_on", "original_dnshost", "original_name_servers", "original_registrar",
    ] {
    fields.remove(field)
  }
  let backend = @client.from_fn((_, _) => {
    json_reply({ "success": true, "result": Json::object(fields) })
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    let result = sdk.get_zone(zone_id="zone")
    guard result is Ok(zone) else { fail(@debug.to_string(result)) }
    assert_eq(zone.id, "zone")
    assert_eq(zone.name, "example.com")
    assert_true(zone.activated_on is Absent)
    assert_true(zone.original_dnshost is Absent)
    assert_true(zone.original_name_servers is Absent)
    assert_true(zone.original_registrar is Absent)
    fields.remove("id")
    assert_true(sdk.get_zone(zone_id="zone") is Err(Decode(_)))
    fields["id"] = "zone"
    fields["name"] = Json::null()
    assert_true(sdk.get_zone(zone_id="zone") is Err(Decode(_)))
  })
}

///|
test "OPENPGPKEY fields remain required while accepting explicit null" {
  let fixture = record_fixture({ "type": "OPENPGPKEY" })
  guard fixture is Object(fields) else { fail("expected a record object") }
  let fields = fields.copy()
  let backend = @client.from_fn((_, _) => {
    json_reply({ "success": true, "result": Json::object(fields) })
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    for key in ["comment", "content", "proxied", "settings", "tags"] {
      fields.remove(key)
      let omitted = sdk.get_dns_record(zone_id="zone", dns_record_id="record")
      assert_true(omitted is Err(Decode(_)))
      fields[key] = Json::null()
      let explicit_null = sdk.get_dns_record(
        zone_id="zone",
        dns_record_id="record",
      )
      assert_true(explicit_null is Ok(@gen.DnsRecordResponse::OPENPGPKEY(_)))
    }
  })
}

///|
test "Cloudflare response envelopes reject an omitted or null result" {
  let responses : Array[Json] = [
    { "success": true },
    { "success": true, "result": Json::null() },
  ]
  for response in responses {
    let backend = @client.from_fn((_, _) => json_reply(response))
    let sdk = @cloudflare_dns.CloudflareDns::new(
      backend,
      @sim.FakeClock::new(),
      auth=ApiToken("fixture"),
    )
    let zone_id = "zone"
    let dns_record_id = "record"
    let zone_create = @gen.ZoneCreate::new(
      account=@gen.ZoneCreateAccount::new(),
      name="example.com",
    )
    @driver.run_sync(() => {
      assert_true(sdk.get_zone(zone_id~) is Err(Decode(_)))
      assert_true(sdk.create_zone(zone_create) is Err(Decode(_)))
      assert_true(
        sdk.edit_zone(zone_id~, @gen.ZonePatch::new()) is Err(Decode(_)),
      )
      assert_true(sdk.trigger_zone_activation_check(zone_id~) is Err(Decode(_)))
      assert_true(
        sdk.get_dns_record(zone_id~, dns_record_id~) is Err(Decode(_)),
      )
      assert_true(
        sdk.delete_dns_record(zone_id~, dns_record_id~) is Err(Decode(_)),
      )
      assert_true(
        sdk.batch_dns_records(zone_id~, @gen.DnsBatch::new()) is Err(Decode(_)),
      )
      assert_true(
        sdk.import_dns_records(zone_id~, zone_file="") is Err(Decode(_)),
      )
      assert_true(
        sdk.review_dns_record_scan(zone_id~, @gen.DnsScanReview::new())
        is Err(Decode(_)),
      )
      assert_true(sdk.get_dnssec(zone_id~) is Err(Decode(_)))
      assert_true(sdk.get_dns_settings(zone_id~) is Err(Decode(_)))
    })
  }
}
