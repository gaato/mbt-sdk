///|
test "Petstore raw builder marks the spec-declared api_key" {
  let raw = @fixture-petstore3.delete_pet_request(1, api_key="fixture-key")
  let raw = { ..raw, url: @http.join_url("https://petstore.example", raw.url), }
  let plan = @client.request(raw).response(@client.as_bytes())
  let seen = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.headers.get("api_key"))
    if request.url == raw.url {
      @http.Response::new(
        307,
        headers=@http.Headers::of([("location", "https://other.example/pet/1")]),
      )
    } else {
      @http.Response::new(200)
    }
  })
  let runtime = @client.Client::new(backend, @sim.FakeClock::new(), redirect={
    ..@client.RedirectConfig::default(),
    credential_headers: [],
  })
  assert_eq(@driver.run_sync(() => runtime.send(plan)).status, 200)
  assert_eq(seen, [Some("fixture-key"), None])
  assert_true(plan.to_curl().contains("api_key: <redacted>"))
  assert_false(plan.to_curl().contains("fixture-key"))
}
