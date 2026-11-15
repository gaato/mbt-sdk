///|
async test "generated badhttp client consumes a replayed response" {
  let document = plain_body(capture("compress.identity"))
  replay(capture("compress.identity"), origin => {
    let client = @client.Client::new(
      transport(),
      @runtime.AsyncClock::new(),
      timeout_ms=5000,
      retry=@client.RetryPolicy::none(),
    )
    defer client.close()
    let sdk = @badhttp.Badhttp::from_client(client, base_url=origin)
    let reply = sdk.send(@badhttp.get_compress_request())
    match reply {
      Ok(reply) => assert_eq(reply.body, document)
      _ => fail("generated client failed against a recorded response")
    }
  })
}
