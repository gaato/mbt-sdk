///|
/// The base URLs and request paths the generated SDKs really send, and what
/// `Client` has always made of them.
test "resolve_url keeps the SDKs' base-and-path joins byte for byte" {
  let cases = [
    // OpenAI: the default base has a path the request path extends.
    (
      "https://api.openai.com/v1", "/chat/completions", "https://api.openai.com/v1/chat/completions",
    ),
    (
      "https://api.openai.com/v1", "/responses", "https://api.openai.com/v1/responses",
    ),
    (
      "https://api.openai.com/v1", "/models/model%2Fid%20with%20space", "https://api.openai.com/v1/models/model%2Fid%20with%20space",
    ),
    (
      "https://proxy.example/openai/v1/", "/embeddings", "https://proxy.example/openai/v1/embeddings",
    ),
    // Anthropic.
    (
      "https://api.anthropic.com", "/v1/messages", "https://api.anthropic.com/v1/messages",
    ),
    (
      "https://api.anthropic.com", "/v1/messages/count_tokens", "https://api.anthropic.com/v1/messages/count_tokens",
    ),
    (
      "https://api.anthropic.com", "/v1/models?limit=20&after_id=m", "https://api.anthropic.com/v1/models?limit=20&after_id=m",
    ),
    // GitHub, including Enterprise Server's /api/v3 base and Link pagination.
    (
      "https://api.github.com", "/repos/o/r/contents/a%2Fb?ref=main", "https://api.github.com/repos/o/r/contents/a%2Fb?ref=main",
    ),
    ("https://ghe.example/api/v3", "/user", "https://ghe.example/api/v3/user"),
    ("https://ghe.example/api/v3/", "/user", "https://ghe.example/api/v3/user"),
    (
      "https://api.github.com", "https://api.github.com/user/repos?page=2", "https://api.github.com/user/repos?page=2",
    ),
    (
      "https://api.github.com", "https://uploads.github.com/repos/o/r/releases/1/assets?name=a.zip",
      "https://uploads.github.com/repos/o/r/releases/1/assets?name=a.zip",
    ),
    (
      "http://127.0.0.1:8080", "http://127.0.0.1:8080/next", "http://127.0.0.1:8080/next",
    ),
    // Joins, not RFC 3986 resolution: nothing is dropped or normalised.
    ("https://h/v1", "models", "https://h/v1/models"),
    ("https://h/v1/", "models", "https://h/v1/models"),
    ("https://h/v1", "", "https://h/v1/"),
    ("https://h", "//cdn/x", "https://h//cdn/x"),
    ("https://h/v1", "../x", "https://h/v1/../x"),
    ("https://h/v1", "?q=1", "https://h/v1/?q=1"),
    ("https://h", "models:generate", "https://h/models:generate"),
    ("https://h", "http:g", "https://h/http:g"),
    ("https://h", "ftp://h/x", "https://h/ftp://h/x"),
    ("https://h", "http://[::1/x", "http://[::1/x"),
  ]
  for case in cases {
    assert_eq((case.0, case.1, resolve_url(case.0, case.1)), case)
  }
  // RFC 3986 resolution would drop OpenAI's /v1, so Client does not use it.
  let rfc = @http.Url::parse("https://api.openai.com/v1").resolve(
    @http.Url::parse("/chat/completions"),
  )
  assert_eq(rfc.to_string(), "https://api.openai.com/chat/completions")
}

///|
test "resolve_url keeps an absolute http(s) URL in any letter case" {
  let cases = [
    ("https://h/v1", "HTTPS://other.example/x", "HTTPS://other.example/x"),
    ("https://h/v1", "Http://other.example", "Http://other.example"),
  ]
  for case in cases {
    assert_eq((case.0, case.1, resolve_url(case.0, case.1)), case)
  }
}

///|
priv struct Unread {}

///|
impl @http.BodyStream for Unread with fn read_some(_) {
  None
}

///|
impl @http.BodyStream for Unread with fn close(_) {
  ()
}

///|
test "can_resend refuses only a stream body a transport has read" {
  let stream = (taken : Bool) => {
    let body = @http.StreamBody::new(Unread::{ })
    if taken {
      ignore(body.take())
    }
    { ..@http.Request::put("/upload"), body: Stream(body), }
  }
  let rows : Array[(@http.Request, Bool, Bool)] = [
    (@http.Request::post("/upload").body_bytes(b"x"), false, true),
    (@http.Request::get("/"), false, true),
    (stream(false), false, true),
    (stream(true), false, false),
    // A body rebuilt for each attempt replaces the one that was read.
    (stream(true), true, true),
  ]
  for row in rows {
    let (request, rebuilt, expected) = row
    assert_eq(
      can_resend(request, rebuilt~),
      expected,
      msg=@debug.to_string(row),
    )
  }
}
