// Executes gaato/http's redirect step against the scripted transport;
// gaato/http cannot run an async test itself.

///|
fn redirect_to(status : Int32, location : String) -> @http.Response {
  {
    status,
    headers: @http.Headers::from_array([("Location", location)]),
    body: b"moved",
  }
}

///|
fn final_ok() -> @http.Response {
  { status: 200, headers: @http.Headers::new(), body: b"done", }
}

///|
fn send_via(
  fake : @mock.FakeTransport,
) -> async (@http.Request) -> @http.Response raise @http.HttpError {
  request => fake.send(request)
}

///|
fn summary(request : @http.Request) -> String {
  let headers = request.headers.iter().map(pair => pair.0).to_array()
  "\{request.http_method} \{request.url} \{@utf8.decode_lossy(request.body)} [\{headers.join(", ")}]"
}

///|
async test "follow_redirects rewrites, strips and reports each hop" {
  let fake = @mock.FakeTransport::new()
  fake.expect(
    "POST",
    "https://api.example/upload",
    redirect_to(302, "/v2/upload?x=é#frag"),
  )
  fake.expect(
    "GET",
    "https://api.example/v2/upload?x=%C3%A9",
    redirect_to(307, "https://cdn.example/o"),
  )
  fake.expect(
    "GET",
    "https://cdn.example/o",
    redirect_to(308, "http://cdn.example/plain"),
  )
  let request = @http.Request::post("https://api.example/upload")
    .header("Authorization", "Bearer t")
    .header("Content-Type", "application/json")
    .header("Accept", "application/json")
    .body_text("{}")
  let hops = []
  let refused = try
    @http.follow_redirects(request, send_via(fake), on_redirect=hop => {
      hops.push(hop)
    })
  catch {
    Downgrade(location~) => location
    _ => "unexpected error"
  } noraise {
    _ => "followed a downgrade"
  }
  assert_eq(refused, "http://cdn.example/plain")
  assert_eq(fake.sent().map(summary), [
    "POST https://api.example/upload {} [authorization, content-type, accept]", "GET https://api.example/v2/upload?x=%C3%A9  [authorization, accept]",
    "GET https://cdn.example/o  [accept]",
  ])
  assert_eq(hops.map(hop => hop.response.status), [302, 307])
  assert_eq(hops.map(hop => hop.request.url), [
    "https://api.example/upload", "https://api.example/v2/upload?x=%C3%A9",
  ])
  assert_eq(hops.map(hop => hop.next.url), [
    "https://api.example/v2/upload?x=%C3%A9", "https://cdn.example/o",
  ])
  fake.assert_complete()
}

///|
async test "307 and 308 resend the method and body; a final response ends the chain" {
  let fake = @mock.FakeTransport::new()
  fake.expect("PUT", "/a", redirect_to(307, "/b"))
  fake.expect("PUT", "/b", redirect_to(308, "/c"))
  fake.expect("PUT", "/c", redirect_to(303, "/d"))
  fake.expect("GET", "/d", final_ok())
  let request = @http.Request::put("http://h/a")
    .header("Content-Type", "text/plain")
    .body_text("payload")
  let response = @http.follow_redirects(request, send_via(fake))
  assert_eq(response.body, b"done")
  assert_eq(fake.sent().map(summary), [
    "PUT http://h/a payload [content-type]", "PUT http://h/b payload [content-type]",
    "PUT http://h/c payload [content-type]", "GET http://h/d  []",
  ])
  fake.assert_complete()
}

///|
async test "a 3xx without Location, or one not followed, is returned as it is" {
  let fake = @mock.FakeTransport::new()
  let no_location : @http.Response = {
    status: 302,
    headers: @http.Headers::new(),
    body: b"",
  }
  fake.expect("GET", "/a", no_location)
  fake.expect("GET", "/b", redirect_to(304, "/elsewhere"))
  let send = send_via(fake)
  assert_eq(
    @http.follow_redirects(@http.Request::get("http://h/a"), send),
    no_location,
  )
  assert_eq(
    @http.follow_redirects(@http.Request::get("http://h/b"), send).status,
    304,
  )
  fake.assert_complete()
}

///|
async test "redirects stop at max_redirects, 10 by default" {
  for max in [None, Some(0), Some(2)] {
    let limit = max.unwrap_or(10)
    let fake = @mock.FakeTransport::new()
    for i in 0..<=limit {
      fake.expect("GET", "/r\{i}", redirect_to(301, "/r\{i + 1}"))
    }
    let hops = []
    let error = try
      @http.follow_redirects(
        @http.Request::get("https://h/r0"),
        send_via(fake),
        max_redirects?=max,
        on_redirect=hop => hops.push(hop),
      )
    catch {
      TooManyRedirects(max~, location~) => (max, location)
      _ => (-1, "unexpected error")
    } noraise {
      _ => (-1, "no error")
    }
    assert_eq(error, (limit, "https://h/r\{limit + 1}"))
    // The limit is followed; the response one past it is not.
    assert_eq(hops.length(), limit)
    assert_eq(fake.sent().length(), limit + 1)
    fake.assert_complete()
  }
}

///|
async test "allow_downgrade follows https to http without credentials" {
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "https://h/a", redirect_to(301, "http://h/b"))
  fake.expect("GET", "http://h/b", redirect_to(301, "https://h/c"))
  fake.expect("GET", "https://h/c", final_ok())
  let request = @http.Request::get("https://h/a")
    .header("Authorization", "Bearer t")
    .header("Cookie", "c=1")
    .header("X-Api-Key", "k")
  let _ = @http.follow_redirects(
    request,
    send_via(fake),
    allow_downgrade=true,
    credential_headers=["x-api-key"],
  )
  // Stripped at the downgrade; the upgrade back does not restore them.
  assert_eq(fake.sent().map(summary), [
    "GET https://h/a  [authorization, cookie, x-api-key]", "GET http://h/b  []",
    "GET https://h/c  []",
  ])
  fake.assert_complete()
}

///|
async test "a same-host upgrade to https keeps credentials" {
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "http://h/a", redirect_to(301, "https://h/a"))
  fake.expect("GET", "https://h/a", redirect_to(302, "https://other/a"))
  fake.expect("GET", "https://other/a", final_ok())
  let request = @http.Request::get("http://h/a")
    .header("Authorization", "Bearer t")
    .header("Host", "h")
  let _ = @http.follow_redirects(request, send_via(fake))
  assert_eq(fake.sent().map(summary), [
    "GET http://h/a  [authorization, host]", "GET https://h/a  [authorization]",
    "GET https://other/a  []",
  ])
  fake.assert_complete()
}

///|
async test "redirects as middleware maps refusals to Protocol and passes transport errors" {
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "/a", redirect_to(302, "/b"))
  fake.expect("GET", "/b", final_ok())
  fake.expect("GET", "/c", redirect_to(302, "/d"))
  fake.expect_error("GET", "/d", @http.HttpError::Timeout(7))
  fake.expect("GET", "/e", redirect_to(302, "ftp://h/f"))
  fake.expect("GET", "/g", redirect_to(302, "/h"))
  let hops = []
  let seen = []
  let log : @http.Middleware = (request, next) => {
    seen.push(request.url)
    next(request)
  }
  let chain = [@http.redirects(max_redirects=0), log]
  let follow = [@http.redirects(on_redirect=hop => hops.push(hop)), log]
  let response = @http.send_with(fake, follow, @http.Request::get("http://h/a"))
  assert_eq(response.body, b"done")
  assert_eq(hops.length(), 1)
  // Every hop goes through the steps after the redirect step.
  assert_eq(seen, ["http://h/a", "http://h/b"])
  let failure = async fn(steps, url) {
    try @http.send_with(fake, steps, @http.Request::get(url)) catch {
      error => @debug.to_string(error)
    } noraise {
      _ => "no error"
    }
  }
  assert_eq(failure(follow, "http://h/c"), "Timeout(7)")
  assert_eq(
    failure(follow, "http://h/e"),
    "Protocol(\"bad redirect Location \\\"ftp://h/f\\\": not an http or https URL\")",
  )
  assert_eq(
    failure(chain, "http://h/g"),
    "Protocol(\"more than 0 redirects; last to http://h/h\")",
  )
  fake.assert_complete()
}

///|
async test "a transport failure mid-chain is RedirectError::Transport" {
  let fake = @mock.FakeTransport::new()
  fake.expect("GET", "/a", redirect_to(302, "/b"))
  fake.expect_error("GET", "/b", @http.HttpError::Connect("refused"))
  let error = try
    @http.follow_redirects(@http.Request::get("http://h/a"), send_via(fake))
  catch {
    Transport(error) => @debug.to_string(error)
    _ => "unexpected error"
  } noraise {
    _ => "no error"
  }
  assert_eq(error, "Connect(\"refused\")")
  fake.assert_complete()
}
