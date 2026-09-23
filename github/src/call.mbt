///|
/// Sends a generated request and decodes the successful response.
///
/// The two arguments are the matched halves of one generated operation, so a
/// call reads as a single line:
///
///     let repo = gh.call(
///       @gen.repos_get_request("gaato", "mbt-sdk"),
///       @gen.repos_get_decode,
///     )
///
/// Failures arrive as `@runtime.SdkError`; `api_error` reads GitHub's error
/// body out of one.
pub async fn[T] GitHub::call(
  self : GitHub,
  request : @http.Request,
  decode : (@http.Response) -> T raise @runtime.SdkError,
) -> T raise @runtime.SdkError {
  decode(self.send(request))
}

///|
/// Sends a generated request and returns the successful response undecoded.
///
/// This is for the operations whose body a decoder cannot describe: `204` and
/// `304` replies, and the representations requested through a non-JSON `accept`
/// such as `application/vnd.github.diff`.
pub async fn GitHub::send(
  self : GitHub,
  request : @http.Request,
) -> @http.Response raise @runtime.SdkError {
  self.client.send(request, bucket=rate_limit_bucket(request.url))
}

///|
/// The rate limit bucket a request URL belongs to.
///
/// GitHub meters search separately from the rest of the REST API, and the two
/// windows are far apart (30 requests per minute against 5,000 per hour), so
/// they must not share a limiter bucket.
///
/// The URL is either the relative path a generated operation produced or the
/// absolute `Link` target of a following page, so the scheme and authority are
/// stripped first, along with the `/api/v3` mount a GitHub Enterprise Server
/// deployment puts in front of every path.
fn rate_limit_bucket(url : String) -> String {
  if request_path(url).has_prefix("/search/") {
    "search"
  } else {
    "core"
  }
}

///|
/// Extracts the path of an absolute or relative request URL.
fn request_path(url : String) -> String {
  let mut rest = url
  let mut absolute = true
  if url.has_prefix("https://") {
    rest = url[8:].to_owned()
  } else if url.has_prefix("http://") {
    rest = url[7:].to_owned()
  } else if url.has_prefix("//") {
    rest = url[2:].to_owned()
  } else {
    absolute = false
  }
  if absolute {
    rest = match rest.find("/") {
      Some(index) => rest[index:].to_owned()
      None => "/"
    }
  }
  if rest.find("#") is Some(index) {
    rest = rest[:index].to_owned()
  }
  if rest.find("?") is Some(index) {
    rest = rest[:index].to_owned()
  }
  if !rest.has_prefix("/") {
    rest = "/" + rest
  }
  if rest.has_prefix("/api/v3/") {
    rest = rest[7:].to_owned()
  }
  rest
}
