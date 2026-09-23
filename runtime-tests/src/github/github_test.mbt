///|
/// The asynchronous behaviour of `gaato/github`, pinned against a scripted
/// transport and a fake clock.
///
/// The facade's own suite is synchronous: it can check that `Client::prepare`
/// leaves a caller's header alone, but it cannot watch a request leave, a
/// `Link` page be followed, a limiter wait, or a retry sleep. Those are here.
fn json_response(
  body : String,
  status? : Int = 200,
  headers? : @http.Headers = @http.Headers::new(),
) -> @http.Response {
  { status, headers, body: @utf8.encode(body), }
}

///|
async fn bounded(f : async () -> Unit) -> Unit {
  @async.with_timeout(5000, f)
}

///|
fn no_limiter() -> &@runtime.RateLimiter {
  @runtime.NoLimiter::new()
}

///|
/// A `Link` value with the relations GitHub actually sends on that page.
fn link_header(pairs : Array[(String, String)]) -> String {
  pairs.map(pair => "<" + pair.0 + ">; rel=\"" + pair.1 + "\"").join(", ")
}

///|
/// One `issues/list-for-repo` element, carrying every field the generated
/// `Issue` decoder requires.
fn issue_fixture(number : Int, title : String) -> String {
  let base = "https://api.github.com/repos/gaato/mbt-sdk/issues/" +
    number.to_string()
  "{\"id\":" +
  (number * 100).to_string() +
  ",\"node_id\":\"I_kw" +
  number.to_string() +
  "\",\"url\":\"" +
  base +
  "\",\"repository_url\":\"https://api.github.com/repos/gaato/mbt-sdk\"" +
  ",\"labels_url\":\"" +
  base +
  "/labels\",\"comments_url\":\"" +
  base +
  "/comments\",\"events_url\":\"" +
  base +
  "/events\",\"html_url\":\"https://github.com/gaato/mbt-sdk/issues/" +
  number.to_string() +
  "\",\"number\":" +
  number.to_string() +
  ",\"state\":\"open\",\"title\":\"" +
  title +
  "\",\"user\":null,\"labels\":[],\"assignee\":null,\"milestone\":null" +
  ",\"locked\":false,\"comments\":0,\"closed_at\":null" +
  ",\"created_at\":\"2024-01-01T00:00:00Z\",\"updated_at\":\"2024-01-02T00:00:00Z\"}"
}

///|
fn issue_page(numbers : Array[Int]) -> String {
  "[" +
  numbers
  .map(number => issue_fixture(number, "issue " + number.to_string()))
  .join(",") +
  "]"
}

///|
/// The headers a rate-limited GitHub response carries.
fn rate_limit_headers(
  remaining : Int,
  reset_unix_seconds : Int,
) -> @http.Headers {
  @http.Headers::from_array([
    ("x-ratelimit-limit", "5000"),
    ("x-ratelimit-remaining", remaining.to_string()),
    ("x-ratelimit-reset", reset_unix_seconds.to_string()),
  ])
}

// -----------------------------------------------------------------------------
// 1. The request that leaves the client.
// -----------------------------------------------------------------------------

///|
async test "GitHub sends the documented defaults and omits auth without a token" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/repos/octocat/Hello-World",
      json_response("{\"id\":1296269,\"full_name\":\"octocat/Hello-World\"}"),
    )
    // Newlines sit between JSON tokens, so the parser reads this as one object.
    // content-file lists its nullable members as required, so an explicit null
    // is not the same as an absent key: git_url, html_url and download_url have
    // to appear. GitHub does send them.
    let readme_content =
      $|{"type":"file","encoding":"base64","size":22,"name":"README.md",
      $|"path":"README.md","content":"SGVsbG8sIEhlbGxvLVdvcmxkIQo=",
      $|"sha":"3d21ec53a331a6f037a91c368710b99387d012c1",
      $|"url":"https://api.github.com/repos/octocat/Hello-World/contents/README.md",
      $|"git_url":null,"html_url":null,"download_url":null,
      $|"_links":{"git":null,"html":null,
      $|"self":"https://api.github.com/repos/octocat/Hello-World/contents/README.md"}}
    transport.expect(
      "GET",
      "/repos/octocat/Hello-World/contents/README.md",
      json_response(readme_content),
    )
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(transport, clock, token="ghp_test")
    ignore(gh.send(@gen.repos_get_request("octocat", "Hello-World")))
    let content = gh.call(
      @gen.repos_get_content_request("octocat", "Hello-World", "README.md"),
      @gen.repos_get_content_decode,
    )
    // repos/get-content answers with either a directory listing or one object;
    // moonbit.yaml keeps the object arm discriminated on "type", so a file comes
    // back as a typed ContentFile rather than as raw Json.
    guard content is Object(File(file)) else {
      fail("expected a file, got \{@debug.to_string(content)}")
    }
    assert_eq(file.path, "README.md")
    assert_eq(file.name, "README.md")
    assert_eq(file.size, 22)
    assert_eq(file.encoding, "base64")
    assert_eq(
      file.links.self,
      "https://api.github.com/repos/octocat/Hello-World/contents/README.md",
    )
    let sent = transport.sent()
    assert_eq(sent.length(), 2)
    assert_eq(sent[0].http_method, "GET")
    assert_eq(sent[0].url, "https://api.github.com/repos/octocat/Hello-World")
    assert_eq(sent[0].body, b"")
    assert_eq(sent[0].headers.get("authorization"), Some("Bearer ghp_test"))
    assert_eq(
      sent[0].headers.get("accept"),
      Some("application/vnd.github+json"),
    )
    assert_eq(sent[0].headers.get("x-github-api-version"), Some("2022-11-28"))
    assert_eq(sent[0].headers.get("user-agent"), Some("gaato-mbt-sdk/0.1.0"))
    assert_eq(sent[0].headers.get("content-type"), None)
    // Exactly the four headers above: no default is sent twice.
    assert_eq(sent[0].headers.length(), 4)
    assert_eq(
      sent[1].url,
      "https://api.github.com/repos/octocat/Hello-World/contents/README.md",
    )
    assert_eq(sent[1].headers, sent[0].headers)
    assert_eq(clock.slept(), [])
    transport.assert_complete()

    // Unauthenticated against a GitHub Enterprise Server mount.
    let anonymous = @mock.FakeTransport::new()
    anonymous.expect(
      "GET",
      "/api/v3/repos/octocat/Hello-World",
      json_response("{}"),
    )
    let ghe = @github_sdk.GitHub::new(
      anonymous,
      @mock.FakeClock::new(),
      base_url="https://ghe.example.com/api/v3",
      api_version="2022-11-01",
      user_agent="my-tool/2",
    )
    ignore(ghe.send(@gen.repos_get_request("octocat", "Hello-World")))
    let anonymous_sent = anonymous.sent()
    assert_eq(
      anonymous_sent[0].url,
      "https://ghe.example.com/api/v3/repos/octocat/Hello-World",
    )
    assert_false(anonymous_sent[0].headers.contains("authorization"))
    assert_eq(
      anonymous_sent[0].headers.get("x-github-api-version"),
      Some("2022-11-01"),
    )
    assert_eq(anonymous_sent[0].headers.get("user-agent"), Some("my-tool/2"))
    assert_eq(anonymous_sent[0].headers.length(), 3)
    anonymous.assert_complete()
  })
}

// -----------------------------------------------------------------------------
// 2. A request header beats the client default, end to end.
// -----------------------------------------------------------------------------

///|
async test "a request header overrides the client default on the wire" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk/compare/main...topic",
      json_response(
        "diff --git a/README.md b/README.md\n",
        headers=@http.Headers::from_array([("content-type", "text/plain")]),
      ),
    )
    let gh = @github_sdk.GitHub::new(
      transport,
      @mock.FakeClock::new(),
      token="ghp_test",
    )
    let response = gh.send(
      @http.Request::get("/repos/gaato/mbt-sdk/compare/main...topic")
      .header("accept", "application/vnd.github.diff")
      .header("user-agent", "diff-fetcher/1"),
    )
    assert_eq(response.text(), "diff --git a/README.md b/README.md\n")
    let sent = transport.sent()
    assert_eq(sent.length(), 1)
    // The caller's media type is what travels, and the client default is not
    // appended alongside it.
    assert_eq(
      sent[0].headers.get("accept"),
      Some("application/vnd.github.diff"),
    )
    assert_eq(sent[0].headers.get_all("accept"), ["application/vnd.github.diff"])
    assert_eq(sent[0].headers.get("user-agent"), Some("diff-fetcher/1"))
    assert_eq(sent[0].headers.get_all("user-agent"), ["diff-fetcher/1"])
    // The default the request did not set is still added, and auth still applies.
    assert_eq(sent[0].headers.get("x-github-api-version"), Some("2022-11-28"))
    assert_eq(sent[0].headers.get("authorization"), Some("Bearer ghp_test"))
    assert_eq(sent[0].headers.length(), 4)
    transport.assert_complete()
  })
}

// -----------------------------------------------------------------------------
// 3. Link pagination.
// -----------------------------------------------------------------------------

///|
/// The absolute next/last targets GitHub writes, which are not rebuilt from the
/// first request: the repository is addressed by id rather than by name.
fn page_url(page : Int) -> String {
  "https://api.github.com/repositories/1300192/issues?per_page=2&page=" +
  page.to_string()
}

///|
fn paging_transport() -> @mock.FakeTransport {
  let transport = @mock.FakeTransport::new()
  transport.expect(
    "GET",
    "https://api.github.com/repos/gaato/mbt-sdk/issues?per_page=2",
    json_response(
      issue_page([1, 2]),
      headers=@http.Headers::from_array([
        ("link", link_header([(page_url(2), "next"), (page_url(3), "last")])),
      ]),
    ),
  )
  transport.expect(
    "GET",
    page_url(2),
    json_response(
      issue_page([3, 4]),
      headers=@http.Headers::from_array([
        (
          "link",
          link_header([
            (page_url(3), "next"),
            (page_url(1), "prev"),
            (page_url(3), "last"),
          ]),
        ),
      ]),
    ),
  )
  transport.expect(
    "GET",
    page_url(3),
    json_response(
      issue_page([5]),
      headers=@http.Headers::from_array([
        ("link", link_header([(page_url(2), "prev"), (page_url(1), "first")])),
      ]),
    ),
  )
  transport
}

///|
async test "Link pagination follows the absolute next URL to the last page" {
  bounded(() => {
    let transport = paging_transport()
    let gh = @github_sdk.GitHub::new(
      transport,
      @mock.FakeClock::new(),
      token="ghp_test",
    )
    let numbers : Array[Int] = []
    gh
    .paginator(
      @gen.issues_list_for_repo_request("gaato", "mbt-sdk", per_page=2),
      @gen.issues_list_for_repo_decode,
    )
    .each(issue => numbers.push(issue.number))
    // Three pages, then the page without rel="next" terminates the walk.
    assert_eq(numbers, [1, 2, 3, 4, 5])
    let sent = transport.sent()
    assert_eq(sent.map(request => request.url), [
      "https://api.github.com/repos/gaato/mbt-sdk/issues?per_page=2",
      page_url(2),
      page_url(3),
    ])
    // The following pages inherit the method, the auth, and the defaults.
    for request in sent {
      assert_eq(request.http_method, "GET")
      assert_eq(request.headers.get("authorization"), Some("Bearer ghp_test"))
      assert_eq(
        request.headers.get("accept"),
        Some("application/vnd.github+json"),
      )
      assert_eq(request.headers.get("x-github-api-version"), Some("2022-11-28"))
    }
    transport.assert_complete()
  })
}

///|
async test "collect stops at max without fetching the page it does not need" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "https://api.github.com/repos/gaato/mbt-sdk/issues?per_page=2",
      json_response(
        issue_page([1, 2]),
        headers=@http.Headers::from_array([
          ("link", link_header([(page_url(2), "next"), (page_url(3), "last")])),
        ]),
      ),
    )
    transport.expect(
      "GET",
      page_url(2),
      json_response(
        issue_page([3, 4]),
        headers=@http.Headers::from_array([
          ("link", link_header([(page_url(3), "next")])),
        ]),
      ),
    )
    let gh = @github_sdk.GitHub::new(
      transport,
      @mock.FakeClock::new(),
      token="ghp_test",
    )
    let titles = gh
      .paginator(
        @gen.issues_list_for_repo_request("gaato", "mbt-sdk", per_page=2),
        @gen.issues_list_for_repo_decode,
      )
      .collect(max=3)
      .map(issue => issue.title)
    assert_eq(titles, ["issue 1", "issue 2", "issue 3"])
    // The third page is never requested: the script holds only two pages and
    // assert_complete would report an unconsumed expectation otherwise.
    assert_eq(transport.sent().length(), 2)
    transport.assert_complete()
  })
}

// -----------------------------------------------------------------------------
// 4. Rate limit observation and waiting.
// -----------------------------------------------------------------------------

///|
async test "an exhausted window makes the next call wait for the reset" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response("{}", headers=rate_limit_headers(0, 60)),
    )
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response("{}", headers=rate_limit_headers(4999, 3600)),
    )
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response("{}", headers=rate_limit_headers(4998, 3600)),
    )
    // The clock starts at the Unix epoch, so `x-ratelimit-reset: 60` is 60s away.
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(transport, clock, token="ghp_test")
    let request = @gen.repos_get_request("gaato", "mbt-sdk")
    ignore(gh.send(request))
    assert_eq(clock.slept(), [])
    ignore(gh.send(request))
    // The limiter waited out the whole window before the second request left.
    assert_eq(clock.slept(), [60000])
    assert_eq(clock.now_unix_ms(), 60000L)
    // A window with requests left is not waited on.
    ignore(gh.send(request))
    assert_eq(clock.slept(), [60000])
    transport.assert_complete()
  })
}

///|
async test "search and core meter in separate buckets" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/search/repositories?q=moonbit",
      json_response(
        "{\"total_count\":0,\"incomplete_results\":false,\"items\":[]}",
        headers=rate_limit_headers(0, 60),
      ),
    )
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response("{}", headers=rate_limit_headers(4999, 3600)),
    )
    transport.expect(
      "GET",
      "/search/repositories?q=moonbit",
      json_response(
        "{\"total_count\":0,\"incomplete_results\":false,\"items\":[]}",
        headers=rate_limit_headers(29, 120),
      ),
    )
    let clock = @mock.FakeClock::new()
    let gh = @github_sdk.GitHub::new(transport, clock, token="ghp_test")
    let search = @gen.search_repos_request("moonbit")
    ignore(gh.send(search))
    // Exhausting search does not hold up a core request.
    ignore(gh.send(@gen.repos_get_request("gaato", "mbt-sdk")))
    assert_eq(clock.slept(), [])
    // The next search still pays for the exhausted search window.
    ignore(gh.send(search))
    assert_eq(clock.slept(), [60000])
    transport.assert_complete()
  })
}

// -----------------------------------------------------------------------------
// 5. Retry and classification.
// -----------------------------------------------------------------------------

///|
async test "a 502 is retried after a backoff and then succeeds" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response("{\"message\":\"Server Error\"}", status=502),
    )
    transport.expect("GET", "/repos/gaato/mbt-sdk", json_response("{}"))
    let clock = @mock.FakeClock::new()
    // from_client pins the jitter source, so the backoff is exact here:
    // 500ms base, jitter 0.2, random 0.5 => 500ms.
    let gh = @github_sdk.GitHub::from_client(
      @runtime.Client::new(
        transport,
        clock,
        base_url="https://api.github.com",
        retry=@runtime.RetryPolicy::default(),
        limiter=no_limiter(),
        random=() => 0.5,
      ),
    )
    ignore(gh.send(@gen.repos_get_request("gaato", "mbt-sdk")))
    assert_eq(clock.slept(), [500])
    assert_eq(transport.sent().length(), 2)
    transport.assert_complete()
  })
}

///|
async test "a 429 is RateLimited and its retry-after drives the wait" {
  bounded(() => {
    let failing = @mock.FakeTransport::new()
    failing.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response(
        "{\"message\":\"You have exceeded a secondary rate limit.\",\"documentation_url\":\"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api\"}",
        status=429,
        headers=@http.Headers::from_array([("retry-after", "60")]),
      ),
    )
    let gh = @github_sdk.GitHub::new(
      failing,
      @mock.FakeClock::new(),
      token="ghp_test",
      retry=@runtime.RetryPolicy::none(),
      limiter=no_limiter(),
    )
    try gh.send(@gen.repos_get_request("gaato", "mbt-sdk")) catch {
      @runtime.RateLimited(retry_after_ms~, ..) as error => {
        assert_eq(retry_after_ms, Some(60000))
        assert_eq(error.status(), Some(429))
        assert_true(error.is_retryable())
        assert_true(@github_sdk.is_secondary_rate_limit(error))
        assert_false(@github_sdk.is_not_modified(error))
      }
      other =>
        fail("429 must classify as RateLimited: " + @debug.to_string(other))
    } noraise {
      _ => fail("429 must fail when retries are disabled")
    }
    failing.assert_complete()

    let retrying = @mock.FakeTransport::new()
    retrying.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response(
        "{\"message\":\"You have exceeded a secondary rate limit.\"}",
        status=429,
        headers=@http.Headers::from_array([("retry-after", "1")]),
      ),
    )
    retrying.expect("GET", "/repos/gaato/mbt-sdk", json_response("{}"))
    let clock = @mock.FakeClock::new()
    let patient = @github_sdk.GitHub::new(
      retrying,
      clock,
      token="ghp_test",
      limiter=no_limiter(),
    )
    ignore(patient.send(@gen.repos_get_request("gaato", "mbt-sdk")))
    // retry-after wins over the backoff schedule.
    assert_eq(clock.slept(), [1000])
    assert_eq(retrying.sent().length(), 2)
    retrying.assert_complete()
  })
}

///|
async test "a 403 separates the secondary limit from the hourly quota" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    // Secondary limit, reported with retry-after and an untouched quota.
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response(
        "{\"message\":\"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.\",\"documentation_url\":\"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api\"}",
        status=403,
        headers=@http.Headers::from_array([
          ("retry-after", "60"),
          ("x-ratelimit-remaining", "4987"),
        ]),
      ),
    )
    // Primary hourly quota: remaining 0 and no retry-after.
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response(
        "{\"message\":\"API rate limit exceeded for 1.2.3.4.\",\"documentation_url\":\"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api\"}",
        status=403,
        headers=rate_limit_headers(0, 3600),
      ),
    )
    // Secondary limit named only in the body.
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response(
        "{\"message\":\"You have exceeded a secondary rate limit.\"}",
        status=403,
      ),
    )
    // A plain authorization failure is neither.
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response(
        "{\"message\":\"Resource not accessible by integration\",\"documentation_url\":\"https://docs.github.com/rest\"}",
        status=403,
      ),
    )
    let gh = @github_sdk.GitHub::new(
      transport,
      @mock.FakeClock::new(),
      token="ghp_test",
      retry=@runtime.RetryPolicy::none(),
      limiter=no_limiter(),
    )
    let request = @gen.repos_get_request("gaato", "mbt-sdk")
    let verdicts : Array[Bool] = []
    for _ in 0..<4 {
      try gh.send(request) catch {
        error => {
          assert_eq(error.status(), Some(403))
          assert_false(error.is_retryable())
          verdicts.push(@github_sdk.is_secondary_rate_limit(error))
        }
      } noraise {
        _ => fail("403 must fail")
      }
    }
    assert_eq(verdicts, [true, false, true, false])
    transport.assert_complete()
  })
}

///|
async test "a 304 answer to a conditional request is recognised" {
  bounded(() => {
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "GET",
      "/repos/gaato/mbt-sdk",
      json_response(
        "",
        status=304,
        headers=@http.Headers::from_array([
          ("etag", "W/\"a1b2c3\""),
          ("x-ratelimit-remaining", "4999"),
        ]),
      ),
    )
    let gh = @github_sdk.GitHub::new(
      transport,
      @mock.FakeClock::new(),
      token="ghp_test",
      retry=@runtime.RetryPolicy::none(),
      limiter=no_limiter(),
    )
    try
      gh.send(
        @gen.repos_get_request("gaato", "mbt-sdk").header(
          "if-none-match", "W/\"a1b2c3\"",
        ),
      )
    catch {
      error => {
        assert_true(@github_sdk.is_not_modified(error))
        assert_false(@github_sdk.is_secondary_rate_limit(error))
        assert_eq(error.status(), Some(304))
        // An empty body is not a GitHub error object.
        assert_eq(@github_sdk.api_error(error), None)
      }
    } noraise {
      _ => fail("304 must be raised, not returned")
    }
    let sent = transport.sent()
    assert_eq(sent[0].headers.get("if-none-match"), Some("W/\"a1b2c3\""))
    transport.assert_complete()
  })
}

// -----------------------------------------------------------------------------
// 6. The error body.
// -----------------------------------------------------------------------------

///|
async test "a 422 validation body is readable through api_error" {
  bounded(() => {
    let body = "{\"message\":\"Validation Failed\",\"errors\":[{\"resource\":\"Issue\",\"field\":\"title\",\"code\":\"missing_field\"},{\"value\":\"nonexistent\",\"resource\":\"Issue\",\"field\":\"milestone\",\"code\":\"invalid\"}],\"documentation_url\":\"https://docs.github.com/rest/issues/issues#create-an-issue\",\"status\":\"422\"}"
    let transport = @mock.FakeTransport::new()
    transport.expect(
      "POST",
      "/repos/gaato/mbt-sdk/issues",
      json_response(body, status=422),
    )
    let gh = @github_sdk.GitHub::new(
      transport,
      @mock.FakeClock::new(),
      token="ghp_test",
      limiter=no_limiter(),
    )
    try
      gh.send(
        @http.Request::post("/repos/gaato/mbt-sdk/issues").json_body({
          "body": "no title",
          "milestone": "nonexistent",
        }),
      )
    catch {
      error => {
        assert_eq(error.status(), Some(422))
        assert_false(error.is_retryable())
        assert_eq(
          @github_sdk.api_error(error),
          Some({
            message: "Validation Failed",
            documentation_url: Some(
              "https://docs.github.com/rest/issues/issues#create-an-issue",
            ),
            status: Some("422"),
            errors: Some([
              { "resource": "Issue", "field": "title", "code": "missing_field" },
              {
                "value": "nonexistent",
                "resource": "Issue",
                "field": "milestone",
                "code": "invalid",
              },
            ]),
          }),
        )
      }
    } noraise {
      _ => fail("422 must fail")
    }
    // A POST is not idempotent, so a failing one is never replayed.
    assert_eq(transport.sent().length(), 1)
    transport.assert_complete()
  })
}
