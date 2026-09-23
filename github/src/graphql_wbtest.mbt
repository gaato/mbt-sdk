///|
test "graphql is metered in its own bucket" {
  // GitHub budgets GraphQL in points on a window of its own: /rate_limit
  // reports `graphql` beside `core` and `search`, and a GraphQL reply names it
  // in x-ratelimit-resource. Sharing a bucket with core would make the limiter
  // wait on a window that is not the one being spent.
  assert_eq(rate_limit_bucket("https://api.github.com/graphql"), "graphql")
  assert_eq(rate_limit_bucket("/graphql"), "graphql")
  // Enterprise Server serves GraphQL outside the /api/v3 REST mount, so the
  // path that reaches the bucket still carries /api.
  assert_eq(rate_limit_bucket("https://ghe.example.com/api/graphql"), "graphql")
  // The other two buckets are unchanged, and nothing else answers to the name.
  assert_eq(rate_limit_bucket("/search/issues?q=x"), "search")
  assert_eq(rate_limit_bucket("/repos/gaato/mbt-sdk"), "core")
  assert_eq(rate_limit_bucket("/repos/gaato/graphql"), "core")
  assert_eq(rate_limit_bucket("/graphql/schema"), "core")
}

///|
test "the graphql endpoint is derived from the rest root" {
  // On GitHub.com the two APIs share a host and the path is appended.
  assert_eq(
    default_graphql_url("https://api.github.com"),
    "https://api.github.com/graphql",
  )
  assert_eq(
    default_graphql_url("https://api.github.com/"),
    "https://api.github.com/graphql",
  )
  // On Enterprise Server REST is mounted at /api/v3 and GraphQL at
  // /api/graphql, so appending would address an endpoint that does not exist.
  assert_eq(
    default_graphql_url("https://ghe.example.com/api/v3"),
    "https://ghe.example.com/api/graphql",
  )
  assert_eq(
    default_graphql_url("https://ghe.example.com/api/v3/"),
    "https://ghe.example.com/api/graphql",
  )
  // A proxy that does not spell the mount that way is appended to, which is
  // what the graphql_url parameter of GitHub::new is for.
  assert_eq(
    default_graphql_url("https://proxy.example.com/github"),
    "https://proxy.example.com/github/graphql",
  )
}

///|
test "a cursor is added to a copy of the variables" {
  let variables : Json = { "owner": "gaato", "name": "mbt-sdk" }
  let first = with_cursor(Some(variables), "after", "Y3Vyc29yOjE=")
  assert_eq(first, {
    "owner": "gaato",
    "name": "mbt-sdk",
    "after": "Y3Vyc29yOjE=",
  })
  // The caller's value is untouched, so a retried page sends the same request.
  assert_eq(variables, { "owner": "gaato", "name": "mbt-sdk" })
  // A query with no other variable still gets one.
  assert_eq(with_cursor(None, "cursor", "abc"), { "cursor": "abc" })
  assert_eq(with_cursor(Some(Json::null()), "cursor", "abc"), {
    "cursor": "abc",
  })
  // An existing cursor is replaced rather than duplicated.
  assert_eq(with_cursor(Some({ "after": "old" }), "after", "new"), {
    "after": "new",
  })
}

///|
test "variables that cannot carry a cursor are rejected" {
  try with_cursor(Some(Json::array([])), "after", "abc") catch {
    @runtime.Config(message) => assert_true(message.contains("after"))
    _ => fail("expected a configuration error")
  } noraise {
    _ => fail("a cursor cannot be threaded through an array of variables")
  }
}
