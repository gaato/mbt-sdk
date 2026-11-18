// Synthetic wire fixtures from the vendored Cloudflare DNS and Zones OpenAPI.
// RFC 5737 example addresses and example.com keep fixtures independent of accounts.

///|
fn json_reply(value : Json, status~ : Int32 = 200) -> @http.Response {
  @http.Response::new(
    status,
    headers=@http.Headers::of([("content-type", "application/json")]),
    body=Bytes(@utf8.encode(value.stringify())),
  )
}

///|
fn zone_fixture(id : String) -> Json {
  {
    "id": Json(id),
    "name": "example.com",
    "account": {},
    "activated_on": Json::null(),
    "created_on": "2026-01-01T00:00:00Z",
    "development_mode": 0,
    "meta": {},
    "modified_on": "2026-01-01T00:00:00Z",
    "name_servers": [],
    "original_dnshost": Json::null(),
    "original_name_servers": Json::null(),
    "original_registrar": Json::null(),
    "owner": {},
    "plan": {},
  }
}

///|
fn record_fixture(request : Json) -> Json {
  guard request is Object(value) else { abort("record must be an object") }
  let fields = value.copy()
  if !fields.contains("content") {
    fields["content"] = ""
  }
  fields["id"] = "record"
  fields["created_on"] = "2026-01-01T00:00:00Z"
  fields["modified_on"] = "2026-01-01T00:00:00Z"
  fields["meta"] = {}
  fields["proxiable"] = true
  fields["name"] = "www.example.com"
  fields["comment"] = ""
  fields["settings"] = {}
  fields["proxied"] = false
  fields["tags"] = []
  fields["ttl"] = 300
  @json.Json::object(fields)
}

///|
fn wire_json(request : @http.Request) -> Json raise {
  guard request.body is @http.Body::Bytes(body) else {
    fail("expected buffered request")
  }
  @json.parse(@utf8.decode(body))
}

///|
test "DNS record pages retain nullable record response fields" {
  let nullable_record = fn(tag : String, keys : Array[String]) {
    let fixture = record_fixture({ "type": Json(tag) })
    guard fixture is Object(fields) else { abort("expected a record object") }
    let fields = fields.copy()
    for key in keys {
      fields[key] = Json::null()
    }
    @json.Json::object(fields)
  }
  let backend = @client.from_fn((_, _) => {
    json_reply({
      "success": true,
      "result": [
        nullable_record("A", [
          "comment", "proxied", "settings", "tags", "comment_modified_on",
        ]),
        nullable_record("SRV", ["content", "data", "tags_modified_on"]),
      ],
      "result_info": { "page": 1, "total_pages": 1 },
    })
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    let pages = sdk.list_dns_records_pages(zone_id="zone")
    let first = pages.next_page()
    guard first
      is Ok(
        Some([@gen.DnsRecordResponse::A(a), @gen.DnsRecordResponse::SRV(srv)]),
      ) else {
      fail(@debug.to_string(first))
    }
    assert_true(
      Json(a)
      is {
        "comment": Null,
        "proxied": Null,
        "settings": Null,
        "tags": Null,
        ..
      },
    )
    assert_true(Json(srv) is { "content": Null, "data": Null, .. })
    assert_true(pages.next_page() is Ok(None))
  })
}

///|
test "nullable zone deletion result can be omitted from the envelope" {
  let backend = @client.from_fn((_, _) => {
    json_reply({ "success": true, "errors": [], "messages": [] })
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    let deleted = sdk.delete_zone(zone_id="zone")
    guard deleted is Ok(None) else { fail(@debug.to_string(deleted)) }
    assert_true(sdk.delete_dnssec(zone_id="zone") is Err(Decode(_)))
  })
}

///|
test "scan trigger requires a valid resultless JSON envelope" {
  for
    body in [
      b"{\"success\":", b"<html>proxy error</html>", b"[]", b"{}", b"{\"success\":true,\"errors\":[],\"messages\":null}",
    ] {
    let backend = @client.from_fn((_, _) => {
      @http.Response::new(200, body=Bytes(body))
    })
    let sdk = @cloudflare_dns.CloudflareDns::new(
      backend,
      @sim.FakeClock::new(),
      auth=ApiToken("fixture"),
    )
    let result = @driver.run_sync(() => {
      sdk.trigger_dns_record_scan(zone_id="zone")
    })
    guard result is Err(Decode(_)) else { fail(@debug.to_string(result)) }
  }
}

///|
test "BIND boundary selection handles thousands of conflicting suffixes" {
  let file = StringBuilder()
  for i in 0..<8192 {
    file.write_string("; moonbit-sdk-" + i.to_string() + "\n")
  }
  // An occurrence of a longer decimal also blocks its shorter prefixes.
  // Leading zeroes and numbers above the counter range do not wrap.
  file.write_string(
    "; moonbit-sdk-81920 moonbit-sdk-08193 moonbit-sdk-184467440737095516160\n",
  )
  let zone_file = file.to_string()
  let request = @gen.dns_records_for_a_zone_import_dns_records_request(
    "zone", zone_file,
  )
  assert_eq(
    request.headers.get("content-type"),
    Some("multipart/form-data; boundary=moonbit-sdk-8193"),
  )
  guard request.body is @http.Body::Bytes(body) else {
    fail("expected a buffered upload")
  }
  assert_true(@utf8.decode(body).contains(zone_file))
}

///|
test "numbered zone pages stop at total_pages or an empty result" {
  for has_total in [true, false] {
    let seen : Array[String] = []
    let backend = @client.from_fn((request, _) => {
      let query = (try! @http.Url::parse(request.url)).query_params()
      let page = Map::from_array(query).get("page").unwrap()
      try! assert_true(query.contains(("per_page", "5")))
      try! assert_true(query.contains(("account.id", "account")))
      seen.push(page)
      let zones = if page == "4" { [] } else { [zone_fixture(page)] }
      if has_total {
        json_reply({
          "result": Json(zones),
          "result_info": { "total_pages": 3 },
        })
      } else {
        json_reply({ "result": Json(zones) })
      }
    })
    let sdk = @cloudflare_dns.CloudflareDns::new(
      backend,
      @sim.FakeClock::new(),
      auth=ApiToken("fixture"),
    )
    @driver.run_sync(() => {
      let pages = sdk.list_zones_pages(page=2, per_page=5, account_id="account")
      let first = pages.next_page()
      guard first is Ok(Some([zone])) else {
        fail("page 2: " + @debug.to_string(first))
      }
      try! assert_eq(zone.id, "2")
      guard pages.next_page() is Ok(Some([zone])) else {
        fail("missing page 3")
      }
      try! assert_eq(zone.id, "3")
      try! assert_true(pages.next_page() is Ok(None))
      try! assert_true(pages.next_page() is Ok(None))
    })
    try! assert_eq(seen, if has_total { ["2", "3"] } else { ["2", "3", "4"] })
  }
}

///|
test "DNS list preserves dotted filters and leaves raw page metadata accessible" {
  let backend = @client.from_fn((request, _) => {
    try! assert_eq(
      request.url,
      "https://api.cloudflare.com/client/v4/zones/zone/dns_records?name.exact=www.example.com&content.contains=192.0.2.&tag.present=owner&per_page=25",
    )
    json_reply({
      "success": true,
      "result": [record_fixture({ "type": "A", "content": "192.0.2.1" })],
      "result_info": {
        "page": 1,
        "per_page": 25,
        "total_pages": 1,
        "count": 1,
        "total_count": 1,
      },
    })
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    guard sdk.list_dns_records(
        zone_id="zone",
        name_exact="www.example.com",
        content_contains="192.0.2.",
        tag_present="owner",
        per_page=25,
      )
      is Ok([@gen.DnsRecordResponse::A(record)]) else {
      fail("missing A record")
    }
    try! assert_eq(record.id, "record")
    let request = @gen.dns_records_for_a_zone_list_dns_records_request(
      "zone",
      name_exact="www.example.com",
      content_contains="192.0.2.",
      tag_present="owner",
      per_page=25,
    )
    guard sdk.send(request) is Ok(raw) else { fail("missing raw response") }
    try! assert_true(
      @json.parse(@utf8.decode(raw.body))
      is { "result_info": { "total_pages": 1, .. }, .. },
    )
  })
}

///|
test "create, edit, and update send the five representative DNS record types" {
  let requests : Array[Json] = [
    { "type": "A", "content": "192.0.2.1" },
    { "type": "MX", "content": "mx.example.com", "priority": 10 },
    { "type": "TXT", "content": "\"hello\"" },
    {
      "type": "SRV",
      "data": {
        "port": 443,
        "priority": 10,
        "target": "www.example.com",
        "weight": 5,
      },
    },
    {
      "type": "CAA",
      "data": { "flags": 0, "tag": "issue", "value": "ca.example.com" },
    },
  ]
  let seen : Array[(@http.Method, Json)] = []
  let backend = @client.from_fn((request, _) => {
    let json = try! wire_json(request)
    seen.push((request.meth, json))
    json_reply({ "success": true, "result": record_fixture(json) })
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    for fixture in requests {
      let post : @gen.DnsRecord = @json.from_json(fixture)
      let patch : @gen.DnsRecordPatch = @json.from_json(fixture)
      let created = sdk.create_dns_record(zone_id="zone", post)
      let edited = sdk.edit_dns_record(
        zone_id="zone",
        dns_record_id="record",
        patch,
      )
      let updated = sdk.update_dns_record(
        zone_id="zone",
        dns_record_id="record",
        post,
      )
      for write in [created, edited, updated] {
        guard write is Ok(_) else { fail(@debug.to_string(write)) }
      }
    }
  })
  for index, fixture in requests {
    try! assert_eq(seen[index * 3], (@http.Method::parse("POST"), fixture))
    try! assert_eq(seen[index * 3 + 1], (@http.Method::parse("PATCH"), fixture))
    try! assert_eq(seen[index * 3 + 2], (@http.Method::parse("PUT"), fixture))
  }
}

///|
test "all 21 request and response record types round trip plus a future type" {
  for
    tag in [
      "A", "AAAA", "CNAME", "MX", "NS", "OPENPGPKEY", "PTR", "TXT", "CAA", "CERT",
      "DNSKEY", "DS", "HTTPS", "LOC", "NAPTR", "SMIMEA", "SRV", "SSHFP", "SVCB",
      "TLSA", "URI",
    ] {
    let request : Json = { "type": Json(tag) }
    let post : @gen.DnsRecord = @json.from_json(request)
    let patch : @gen.DnsRecordPatch = @json.from_json(request)
    try! assert_false(post is @gen.DnsRecord::Unknown(_, _))
    try! assert_false(patch is @gen.DnsRecordPatch::Unknown(_, _))
    try! assert_eq(Json(post), request)
    try! assert_eq(Json(patch), request)
    let reply = record_fixture({
      "type": Json(tag),
      "content": "example.com",
      "data": {},
      "priority": 10,
    })
    let decoded : @gen.DnsRecordResponse = @json.from_json(reply)
    try! assert_false(decoded is @gen.DnsRecordResponse::Unknown(_, _))
    let rendered = Json(decoded)
    guard rendered is { "type": String(encoded_tag), "id": "record", .. } else {
      fail("lost tag or record metadata")
    }
    try! assert_eq(encoded_tag, tag)
    let roundtrip : @gen.DnsRecordResponse = @json.from_json(rendered)
    try! assert_eq(roundtrip, decoded)
  }
  let raw : Json = { "type": "FUTURE", "extras": { "preserved": true } }
  let post : @gen.DnsRecord = @json.from_json(raw)
  let patch : @gen.DnsRecordPatch = @json.from_json(raw)
  let reply : @gen.DnsRecordResponse = @json.from_json(raw)
  try! assert_true(post is @gen.DnsRecord::Unknown("FUTURE", _))
  try! assert_true(patch is @gen.DnsRecordPatch::Unknown("FUTURE", _))
  try! assert_true(reply is @gen.DnsRecordResponse::Unknown("FUTURE", _))
  try! assert_eq(Json(post), raw)
  try! assert_eq(Json(patch), raw)
  try! assert_eq(Json(reply), raw)
}

///|
test "batch retains IDs and emits inferred tags for constructor-built records" {
  let backend = @client.from_fn((request, _) => {
    try! assert_true(request.url.has_suffix("/zones/zone/dns_records/batch"))
    let body = try! wire_json(request)
    try! assert_eq(body, {
      "deletes": [{ "id": "old" }],
      "patches": [{ "id": "edit", "type": "A", "content": "192.0.2.1" }],
      "puts": [{ "id": "put", "type": "A", "content": "192.0.2.2" }],
      "posts": [{ "type": "A", "content": "192.0.2.3" }],
    })
    let a = record_fixture({ "type": "A", "content": "192.0.2.3" })
    json_reply({
      "result": { "posts": [a], "patches": [a], "puts": [a], "deletes": [a] },
    })
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  let body = @gen.DnsBatch::new(
    deletes=[@gen.BatchRecordDelete::new(id="old")],
    patches=[A(@gen.BatchRecordPatchA::new(id="edit", content="192.0.2.1"))],
    puts=[A(@gen.BatchRecordPutA::new(id="put", content="192.0.2.2"))],
    posts=[A(@gen.ARecord::new(content="192.0.2.3"))],
  )
  guard @driver.run_sync(() => sdk.batch_dns_records(zone_id="zone", body))
    is Ok(reply) else {
    fail("batch did not decode")
  }
  try! assert_true(reply.posts is Some([@gen.DnsRecordResponse::A(_)]))
}

///|
test "DNS BIND import sends multipart bytes and export distinguishes text and errors" {
  // These initial candidates occur inside a BIND comment, away from a MIME
  // delimiter. The generated builder must skip both and preserve the bytes.
  let bind = "; contains moonbit-sdk-0 and moonbit-sdk-1\nwww.example.com. 300 IN A 192.0.2.1\n"
  let count = Ref(0)
  let backend = @client.from_fn((request, _) => {
    count.val += 1
    match count.val {
      1 | 2 => {
        try! assert_true(request.url.has_suffix("/dns_records/import"))
        try! assert_eq(
          request.headers.get("content-type"),
          Some("multipart/form-data; boundary=moonbit-sdk-2"),
        )
        guard request.body is @http.Body::Bytes(body) else {
          abort("expected multipart bytes")
        }
        let proxied = if count.val == 1 { "true" } else { "false" }
        try! assert_eq(
          @utf8.decode(body),
          "--moonbit-sdk-2\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\n" +
          bind +
          "\r\n--moonbit-sdk-2\r\nContent-Disposition: form-data; name=\"proxied\"\r\n\r\n" +
          proxied +
          "\r\n--moonbit-sdk-2--\r\n",
        )
        json_reply({ "result": { "recs_added": 1, "total_records_parsed": 1 } })
      }
      3 => {
        try! assert_true(request.url.has_suffix("/dns_records/export"))
        try! assert_eq(request.headers.get("accept"), Some("text/plain"))
        @http.Response::new(
          200,
          headers=@http.Headers::of([("content-type", "text/plain")]),
          body=Bytes(@utf8.encode(bind)),
        )
      }
      _ =>
        json_reply(
          {
            "success": false,
            "errors": [{ "code": 1000, "message": "offline" }],
          },
          status=403,
        )
    }
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    for proxied in [true, false] {
      guard sdk.import_dns_records(zone_id="zone", zone_file=bind, proxied~)
        is Ok(reply) else {
        fail("import response missing")
      }
      try! assert_eq(reply.recs_added, Some(1))
    }
    guard sdk.export_dns_records(zone_id="zone") is Ok(text) else {
      fail("export text missing")
    }
    try! assert_eq(text, bind)
    guard sdk.export_dns_records(zone_id="zone") is Err(Http(error)) else {
      fail("export error missing")
    }
    try! assert_eq(error.head.status, 403)
    try! assert_eq(error.errors[0].code, 1000)
  })
}

///|
test "HTTP errors and successful statuses reporting failure retain structured diagnostic data" {
  let body =
    #|{"success":false,"errors":[{"code":1000,"message":"invalid","documentation_url":"https://example.com/error","source":{"pointer":"/name"}}],"messages":[{"code":1001,"message":"context"}],"result":null}
  for status in [400, 200] {
    let backend = @client.from_fn((_, _) => {
      @http.Response::new(
        status,
        headers=@http.Headers::of([("x-request-id", "offline")]),
        body=Bytes(@utf8.encode(body)),
      )
    })
    let sdk = @cloudflare_dns.CloudflareDns::new(
      backend,
      @sim.FakeClock::new(),
      auth=ApiToken("fixture"),
    )
    guard @driver.run_sync(() => sdk.list_zones()) is Err(Http(error)) else {
      fail("missing HTTP failure")
    }
    try! assert_eq(error.head.status, status)
    try! assert_eq(error.head.headers.get("x-request-id"), Some("offline"))
    try! assert_eq(error.body, @utf8.encode(body))
    try! assert_eq(
      error.errors[0].documentation_url,
      Some("https://example.com/error"),
    )
    try! assert_eq(error.errors[0].source_pointer, Some("/name"))
    try! assert_eq(error.messages[0].message, "context")
  }
}

///|
test "empty 429 waits five virtual minutes before resending POST" {
  let driver = @driver.Driver::new(auto_advance=true)
  let clock = @sim.SimClock::new(driver)
  let calls : Array[Int64] = []
  let backend = @client.from_fn((request, options) => {
    try! assert_eq(request.meth, @http.Method::parse("POST"))
    try! assert_eq(options.timeout_ms, Some(60000))
    calls.push(driver.now())
    @http.Response::new(
      429,
      headers=@http.Headers::of([("retry-after", "300")]),
    )
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    clock,
    auth=ApiToken("fixture"),
  )
  let result = driver.run(() => sdk.send(@http.Request::post("/zones")))
  guard result is Err(Http(failure)) else { fail("missing final HTTP failure") }
  try! assert_eq(failure.head.status, 429)
  try! assert_eq(failure.body, b"")
  try! assert_true(failure.errors.is_empty())
  try! assert_eq(calls, [0L, 300000L, 600000L])
}

///|
test "server overrides and transport retry distinguish safe replay" {
  for
    (verb, status, decision_header, expected) in [
      ("POST", 500, "", 1),
      ("PATCH", 500, "true", 1),
      ("POST", 429, "", 2),
      ("POST", 429, "false", 1),
      ("GET", 500, "", 2),
      ("PUT", 409, "", 2),
      ("GET", 418, "true", 2),
    ] {
    let count = Ref(0)
    let clock = @sim.FakeClock::new()
    let backend = @client.from_fn((_, _) => {
      count.val += 1
      if count.val == 1 {
        let headers = @http.Headers::of([
          ("retry-after", "300"),
          ("retry-after-ms", "123"),
        ])
        let headers = if decision_header == "" {
          headers
        } else {
          headers.set("x-should-retry", decision_header)
        }
        @http.Response::new(status, headers~)
      } else {
        @http.Response::new(200)
      }
    })
    let sdk = @cloudflare_dns.CloudflareDns::new(
      backend,
      clock,
      auth=ApiToken("fixture"),
    )
    ignore(
      @driver.run_sync(() => {
        sdk.send(@http.Request::new(@http.Method::parse(verb), "/zones"))
      }),
    )
    try! assert_eq(count.val, expected)
    try! assert_eq(clock.slept(), if expected == 1 { [] } else { [123] })
  }
  for (kind, expected) in [(@http.Kind::Refused, 2), (@http.Kind::Network, 1)] {
    let count = Ref(0)
    let backend = @client.from_fn((_, _) => {
      count.val += 1
      if count.val == 1 {
        raise @http.TransportError(kind~, phase=Head, detail="offline")
      }
      @http.Response::new(200)
    })
    let sdk = @cloudflare_dns.CloudflareDns::new(
      backend,
      @sim.FakeClock::new(),
      auth=ApiToken("fixture"),
    )
    ignore(@driver.run_sync(() => sdk.send(@http.Request::post("/zones"))))
    try! assert_eq(count.val, expected)
  }
}

///|
// The real runtime clock suspends the caller. A simulated clock shows that
// cancelling the owner during that suspension prevents a second attempt.
test "cancellation interrupts a server-directed retry wait" {
  let driver = @driver.Driver::new(auto_advance=true)
  let calls = Ref(0)
  let backend = @client.from_fn((_, _) => {
    calls.val += 1
    @http.Response::new(
      429,
      headers=@http.Headers::of([("retry-after", "300")]),
    )
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.SimClock::new(driver),
    auth=ApiToken("fixture"),
  )
  driver.run(() => {
    let worker = driver.spawn(() => ignore(sdk.list_zones()))
    driver.sleep(20)
    worker.cancel()
    ignore(worker.wait())
    assert_true(worker.is_cancelled())
    assert_eq(driver.now(), 20L)
  })
  assert_eq(calls.val, 1)
}

///|
test "DNSSEC delete, scan trigger, and zone delete retain their distinct success payloads" {
  let backend = @client.from_fn((request, _) => {
    if request.url.has_suffix("/dnssec") {
      try! assert_eq(request.meth, @http.Method::parse("DELETE"))
      json_reply({ "success": true, "result": "" })
    } else if request.url.has_suffix("/dns_records/scan/trigger") {
      try! assert_eq(request.meth, @http.Method::parse("POST"))
      json_reply({ "success": true, "errors": [], "messages": [] })
    } else {
      try! assert_eq(request.meth, @http.Method::parse("DELETE"))
      if request.url.has_suffix("/zone-with-id") {
        json_reply({ "result": { "id": "zone-with-id" } })
      } else {
        json_reply({ "result": Json::null() })
      }
    }
  })
  let sdk = @cloudflare_dns.CloudflareDns::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiToken("fixture"),
  )
  @driver.run_sync(() => {
    assert_true(sdk.delete_dnssec(zone_id="zone") is Ok(""))
    let scan : Result[Unit, @cloudflare_dns.Failure] = sdk.trigger_dns_record_scan(
      zone_id="zone",
    )
    assert_true(scan is Ok(_))
    assert_true(sdk.delete_zone(zone_id="zone") is Ok(None))
    guard sdk.delete_zone(zone_id="zone-with-id") is Ok(Some(deleted)) else {
      fail("expected the deleted zone ID")
    }
    assert_eq(deleted.id, "zone-with-id")
  })
}
