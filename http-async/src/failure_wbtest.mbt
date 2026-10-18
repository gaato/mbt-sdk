///|
/// The error `@ahttp.Client` raises for `uri`, which it refuses before
/// connecting.
async fn refusal(uri : String) -> Error {
  try @ahttp.Client(uri) catch {
    error => error
  } noraise {
    client => {
      client.close()
      fail("\{uri} was accepted")
    }
  }
}

///|
async test "failure turns the client's URL refusals into Protocol" {
  let rows : Array[(String, String)] = [
    ("http://h/path", "Protocol(\"invalid URL\")"),
    ("ftp://h", "Protocol(\"unsupported protocol: ftp\")"),
  ]
  for row in rows {
    let (uri, expected) = row
    assert_eq(@debug.to_string(failure(Dial, refusal(uri))), expected)
  }
}
