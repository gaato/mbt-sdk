///|
fn decode_error(body : Bytes) -> @runtime.SdkError {
  @runtime.Decode(message="graphql: …", body~)
}

///|
test "graphql_errors reads a GitHub error envelope" {
  // The shape GitHub answers a query that names a repository it cannot see:
  // HTTP 200, a null data field, and a typed entry in errors.
  let not_found =
    #|{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","path":["repository"],"locations":[{"line":2,"column":3}],"message":"Could not resolve to a Repository with the name 'gaato/nope'."}]}
  guard @github.graphql_errors(decode_error(body(not_found))) is Some(errors) else {
    fail("expected a decoded errors array")
  }
  assert_eq(errors.length(), 1)
  assert_eq(errors[0].type_, Some("NOT_FOUND"))
  assert_eq(
    errors[0].message,
    "Could not resolve to a Repository with the name 'gaato/nope'.",
  )
  assert_eq(errors[0].path, Some(["repository"]))
  assert_eq(errors[0].locations, Some([{ "line": 2, "column": 3 }]))
  assert_eq(errors[0].extensions, None)
}

///|
test "graphql_errors keeps a path that mixes field names with list indices" {
  // A GraphQL path addresses a value in the response, so it indexes lists by
  // number. Nothing narrower than Json holds both.
  let mixed =
    #|{"errors":[{"message":"Something went wrong.","path":["repository","issues","nodes",3,"author"]}]}
  guard @github.graphql_errors(decode_error(body(mixed))) is Some(errors) else {
    fail("expected a decoded errors array")
  }
  assert_eq(
    errors[0].path,
    Some(["repository", "issues", "nodes", 3, "author"]),
  )
  // Only message is required by the GraphQL specification, and a parse error
  // carries nothing else.
  assert_eq(errors[0].type_, None)
  assert_eq(errors[0].locations, None)
}

///|
test "graphql_errors keeps the rate limit condition readable" {
  // A GraphQL rate limit is not an HTTP status either: it is an ordinary entry
  // in the errors array of a 200.
  let limited =
    #|{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user ID 1."}]}
  guard @github.graphql_errors(decode_error(body(limited))) is Some(errors) else {
    fail("expected a decoded errors array")
  }
  assert_eq(errors[0].type_, Some("RATE_LIMITED"))
}

///|
test "graphql_errors keeps every entry of a multi-error envelope" {
  let several =
    #|{"data":null,"errors":[{"message":"first"},{"message":"second"},{"message":"third"}]}
  guard @github.graphql_errors(decode_error(body(several))) is Some(errors) else {
    fail("expected a decoded errors array")
  }
  assert_eq(errors.map(error => error.message), ["first", "second", "third"])
}

///|
test "graphql_errors declines everything that is not a GraphQL envelope" {
  // An unauthenticated request to the GraphQL endpoint is answered 403 with a
  // REST error body, which api_error reads and this one must not claim.
  let rest =
    #|{"message":"API rate limit exceeded for 203.0.113.1.","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}
  assert_eq(@github.graphql_errors(status_error(403, body=body(rest))), None)
  assert_eq(
    @github.api_error(status_error(403, body=body(rest))) is Some(_),
    true,
  )
  // A successful envelope has no errors array at all.
  let ok =
    #|{"data":{"viewer":{"login":"gaato"}}}
  assert_eq(@github.graphql_errors(decode_error(body(ok))), None)
  // Neither has a body that is empty, not JSON, or not an object.
  assert_eq(@github.graphql_errors(decode_error(b"")), None)
  assert_eq(
    @github.graphql_errors(decode_error(body("<html>502</html>"))),
    None,
  )
  assert_eq(@github.graphql_errors(decode_error(body("[]"))), None)
  // A transport or configuration failure carries no body to read.
  assert_eq(@github.graphql_errors(@runtime.Config("no token")), None)
}
