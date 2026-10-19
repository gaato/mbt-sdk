///|
test "rate limit bucket separates search from the rest of the API" {
  // Relative paths, as the generated operations build them.
  assert_eq(
    rate_limit_bucket("GET", "/search/repositories?q=moonbit"),
    "search",
  )
  assert_eq(
    rate_limit_bucket("GET", "/search/code?q=addr%3Ain%3Afile"),
    "search",
  )
  assert_eq(rate_limit_bucket("GET", "/repos/gaato/mbt-sdk"), "core")
  assert_eq(rate_limit_bucket("GET", "/rate_limit"), "core")
  assert_eq(rate_limit_bucket("GET", "/"), "core")
  // Absolute URLs, as a Link header hands them back for the following page.
  assert_eq(
    rate_limit_bucket("GET", "https://api.github.com/search/issues?q=x&page=2"),
    "search",
  )
  assert_eq(
    rate_limit_bucket("GET", "https://api.github.com/users/gaato/repos?page=3"),
    "core",
  )
  // A GitHub Enterprise Server mount keeps its bucket.
  assert_eq(
    rate_limit_bucket("GET", "https://ghe.example.com/api/v3/search/users?q=x"),
    "search",
  )
  assert_eq(
    rate_limit_bucket("GET", "https://ghe.example.com/api/v3/repos/o/r"),
    "core",
  )
  // A repository named "search" is not the search API.
  assert_eq(rate_limit_bucket("GET", "/repos/gaato/search/issues"), "core")
  // "/search" alone is not an endpoint, and neither is a prefix match on it.
  assert_eq(rate_limit_bucket("GET", "/search"), "core")
  assert_eq(rate_limit_bucket("GET", "/searching/x"), "core")
}

///|
test "request_path strips the authority, the query, and the fragment" {
  assert_eq(request_path("https://api.github.com/repos/o/r"), "/repos/o/r")
  assert_eq(request_path("http://localhost:3000/repos/o/r?a=1"), "/repos/o/r")
  assert_eq(request_path("//api.github.com/repos/o/r#x"), "/repos/o/r")
  assert_eq(request_path("https://api.github.com"), "/")
  assert_eq(request_path("/repos/o/r?path=a%2Fb#frag"), "/repos/o/r")
  assert_eq(request_path("repos/o/r"), "/repos/o/r")
  // A path parameter may carry slashes; only the leading mount is removed.
  assert_eq(
    request_path("/repos/o/r/contents/docs/api/v3/index.md"),
    "/repos/o/r/contents/docs/api/v3/index.md",
  )
}

///|
test "default headers carry the version, the media type, and a user agent" {
  let headers = default_headers(
    api_version="2022-11-28",
    user_agent="gaato-mbt-sdk/0.1.0",
  )
  assert_eq(headers.get("accept"), Some("application/vnd.github+json"))
  assert_eq(headers.get("x-github-api-version"), Some("2022-11-28"))
  assert_eq(headers.get("user-agent"), Some("gaato-mbt-sdk/0.1.0"))
  assert_eq(headers.length(), 3)
}

///|
test "a request that sets a default header keeps its own value" {
  // @runtime.Client::prepare appends a default only when the request does not
  // already carry that name, so an operation asking for a non-JSON
  // representation overrides the client's accept header. Pinning the mechanism
  // here: the names the client defaults are exactly the names a request can
  // set, and Headers reports the request's own value for each of them.
  let defaults = default_headers(
    api_version="2022-11-28",
    user_agent="gaato-mbt-sdk/0.1.0",
  )
  let request = @http.Request::get("/repos/o/r/compare/main...topic")
    .header("accept", "application/vnd.github.diff")
    .header("user-agent", "my-tool/2")
  for pair in defaults.iter() {
    if pair.0 == "x-github-api-version" {
      assert_false(request.headers.contains(pair.0))
    } else {
      assert_true(request.headers.contains(pair.0))
    }
  }
  assert_eq(request.headers.get("accept"), Some("application/vnd.github.diff"))
  assert_eq(request.headers.get("user-agent"), Some("my-tool/2"))
}

///|
test "writes get buckets of their own, notification-sending ones apart" {
  assert_eq(rate_limit_bucket("HEAD", "/repos/o/r"), "core")
  assert_eq(rate_limit_bucket("get", "/search/issues?q=x"), "search")
  assert_eq(rate_limit_bucket("POST", "/repos/o/r/labels"), "core:write")
  assert_eq(rate_limit_bucket("PATCH", "/repos/o/r"), "core:write")
  assert_eq(
    rate_limit_bucket("DELETE", "/repos/o/r/issues/1/lock"),
    "core:write",
  )
  assert_eq(
    rate_limit_bucket("POST", "/repos/o/r/issues"),
    "core:notifications",
  )
  assert_eq(
    rate_limit_bucket(
      "POST", "https://api.github.com/repos/o/r/issues/7/comments",
    ),
    "core:notifications",
  )
  assert_eq(
    rate_limit_bucket("PUT", "/repos/o/r/pulls/3/merge"),
    "core:notifications",
  )
  assert_eq(
    rate_limit_bucket(
      "POST", "https://ghe.example.com/api/v3/repos/o/r/releases",
    ),
    "core:notifications",
  )
  // Reading a notification path is a read.
  assert_eq(rate_limit_bucket("GET", "/repos/o/r/issues"), "core")
  // A write to a search path is still a write, as octokit counts it.
  assert_eq(rate_limit_bucket("POST", "/search/issues"), "core:write")
  // GraphQL keeps its bucket whatever the method.
  assert_eq(rate_limit_bucket("POST", "/graphql"), "graphql")
}

///|
test "notification paths match whole segments" {
  assert_true(triggers_notification("/repos/o/r/issues"))
  assert_true(triggers_notification("/REPOS/o/r/Issues"))
  assert_true(triggers_notification("/orgs/acme/invitations/12"))
  assert_true(triggers_notification("/repos/o/r/issues/1/sub_issues/priority"))
  assert_true(triggers_notification("/teams/9/discussions/2/comments"))
  // A parameter is one non-empty segment.
  assert_false(triggers_notification("/repos/o/x/r/issues"))
  assert_false(triggers_notification("/repos//r/issues"))
  // A longer, shorter or merely prefixed path does not match.
  assert_false(triggers_notification("/repos/o/r/issues/1"))
  assert_false(triggers_notification("/repos/o/r"))
  assert_false(triggers_notification("/repos/o/r/issuesx"))
  assert_false(triggers_notification("/repos/o/r/issues/"))
  assert_eq(notification_paths.length(), 19)
}

///|
test "pace spaces writes, graphql, notifications and search" {
  assert_eq(github_pace("core:write"), {
    group: "write",
    min_interval_ms: 1000,
  })
  assert_eq(github_pace("graphql"), { group: "write", min_interval_ms: 1000, })
  assert_eq(github_pace("graphql:mutation"), {
    group: "write",
    min_interval_ms: 1000,
  })
  assert_eq(github_pace("core:notifications"), {
    group: "write",
    min_interval_ms: 3000,
  })
  assert_eq(github_pace("search"), { group: "search", min_interval_ms: 2000, })
  assert_eq(github_pace("core"), { group: "core", min_interval_ms: 0, })
}
