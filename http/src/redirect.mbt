// Redirect following, after the WHATWG Fetch Standard's HTTP-redirect fetch
// and httpx's `_build_redirect_request`: RFC 9110 §15.4 leaves the method
// rewrite of 301 and 302 to the client, and every browser, httpx and Req
// rewrite POST to GET.

///|
/// Why a redirect was not followed. A separate error rather than new
/// `HttpError` variants, which would break exhaustive matches downstream;
/// `redirects` reports these as `HttpError::Protocol`.
pub(all) suberror RedirectError {
  /// A request in the chain failed in the transport.
  Transport(HttpError)
  /// The response was a redirect after `max` had already been followed.
  TooManyRedirects(max~ : Int32, location~ : String)
  /// An `https` request was redirected to `http` and downgrades are refused.
  Downgrade(location~ : String)
  /// The `Location` did not resolve to an absolute `http` or `https` URL
  /// with a host.
  BadLocation(location~ : String, reason~ : String)
  /// The redirect keeps the method and body, and the body is a stream that
  /// was already sent (`Body::is_replayable` is false), as Fetch refuses.
  UnreplayableBody(location~ : String)
} derive(Debug)

///|
/// Debug representation of a refused redirect.
pub extend RedirectError with @debug.Debug::{to_repr}

///|
/// One redirect followed: the request, the 3xx response it got, and the
/// request sent next.
pub struct RedirectHop {
  request : Request
  response : Response
  next : Request
} derive(Debug)

///|
/// Debug representation of a hop.
pub extend RedirectHop with @debug.Debug::{to_repr}

///|
/// Sends `request` through `send`, following 301, 302, 303, 307 and 308
/// responses that carry a `Location`, at most `max_redirects` times.
///
/// The `Location` is resolved against the request URL (RFC 3986 §5.2) and
/// its fragment is not sent. 303 turns any method but HEAD into GET, 301 and
/// 302 turn POST into GET; 307 and 308 keep the method and body. A redirect
/// that would send a stream body again raises `UnreplayableBody`, since the
/// stream was read by the first request; a request turned into GET does not
/// need it. A request
/// turned into GET loses its body and the headers describing it
/// (`Content-Length`, `Content-Type`, `Transfer-Encoding`, and Fetch's
/// `Content-Encoding`, `Content-Language`, `Content-Location`). When the
/// origin changes, `Authorization`, `Cookie`, `Proxy-Authorization`, `Host`
/// and the `credential_headers` are removed, except on an upgrade from
/// `http` on port 80 to `https` on port 443 of the same host, which httpx
/// also allows. Removed headers stay removed for the rest of the chain.
///
/// An `https` request redirected to `http` raises `Downgrade` unless
/// `allow_downgrade` is set; credentials are then stripped as for any origin
/// change. A response without a `Location` is returned as it is.
/// `on_redirect` sees each hop before its request is sent; the step keeps
/// none of them, so a caller collecting a history holds at most
/// `max_redirects` hops.
pub async fn follow_redirects(
  request : Request,
  send : async (Request) -> Response raise HttpError,
  max_redirects~ : Int32 = 10,
  allow_downgrade~ : Bool = false,
  credential_headers~ : Array[String] = [],
  on_redirect? : (RedirectHop) -> Unit,
) -> Response raise RedirectError {
  let mut request = request
  for followed = 0; ; followed = followed + 1 {
    let response = send(request) catch { error => raise Transport(error) }
    guard plan_redirect(
        request,
        { status: response.status, headers: response.headers, },
        followed~,
        max_redirects~,
        allow_downgrade~,
        credential_headers~,
      )
      is Some(next) else {
      return response
    }
    if on_redirect is Some(callback) {
      callback({ request, response, next, })
    }
    request = next
  }
}

///|
/// One redirect followed by `follow_redirects_stream`: the request, the head
/// of the 3xx response it got (its body was closed unread), and the request
/// sent next.
pub struct StreamRedirectHop {
  request : Request
  head : ResponseHead
  next : Request
} derive(Debug)

///|
/// Debug representation of a hop.
pub extend StreamRedirectHop with @debug.Debug::{to_repr}

///|
/// `follow_redirects` for streamed responses, with the same rules and limit:
/// sends through `send_stream` and returns the head and body of the first
/// response that is not a redirect to follow, unread.
///
/// Each 3xx body is closed unread before the next request goes out, and on
/// every error after its head arrived, so only the returned stream stays
/// open. A closed, undrained stream is not reused by a pooling transport,
/// which costs a connection per hop but never reads a redirect body of
/// unknown size.
pub async fn follow_redirects_stream(
  request : Request,
  send_stream : async (Request) -> (ResponseHead, &BodyStream) raise HttpError,
  max_redirects~ : Int32 = 10,
  allow_downgrade~ : Bool = false,
  credential_headers~ : Array[String] = [],
  on_redirect? : (StreamRedirectHop) -> Unit,
) -> (ResponseHead, &BodyStream) raise RedirectError {
  let mut request = request
  for followed = 0; ; followed = followed + 1 {
    let (head, stream) = send_stream(request) catch {
      error => raise Transport(error)
    }
    let planned = {
      errdefer stream.close()
      plan_redirect(
        request,
        head,
        followed~,
        max_redirects~,
        allow_downgrade~,
        credential_headers~,
      )
    }
    guard planned is Some(next) else { return (head, stream) }
    stream.close()
    if on_redirect is Some(callback) {
      callback({ request, head, next, })
    }
    request = next
  }
}

///|
/// `follow_redirects` as a middleware step. A refused redirect raises
/// `HttpError::Protocol` with the reason, a transport failure its own error;
/// call `follow_redirects` directly to match on `RedirectError`.
///
/// ```mbt check
/// test {
///   let _ : @http.Middleware = @http.redirects(max_redirects=5)
/// }
/// ```
pub fn redirects(
  max_redirects~ : Int32 = 10,
  allow_downgrade~ : Bool = false,
  credential_headers~ : Array[String] = [],
  on_redirect? : (RedirectHop) -> Unit,
) -> Middleware {
  (request, next) => {
    follow_redirects(
      request,
      next,
      max_redirects~,
      allow_downgrade~,
      credential_headers~,
      on_redirect?,
    ) catch {
      error => raise redirect_failure(error)
    }
  }
}

///|
/// The `HttpError` a middleware step raises for a refused redirect.
fn redirect_failure(error : RedirectError) -> HttpError {
  match error {
    Transport(error) => error
    TooManyRedirects(max~, location~) =>
      Protocol(
        "more than " + max.to_string() + " redirects; last to " + location,
      )
    Downgrade(location~) => Protocol("refused redirect to http: " + location)
    BadLocation(location~, reason~) =>
      Protocol("bad redirect Location " + location.escape() + ": " + reason)
    UnreplayableBody(location~) =>
      Protocol(
        "refused redirect to " +
        location +
        ": the stream request body was already sent",
      )
  }
}

///|
/// The request to send after a response with this head, or None when it is
/// not a redirect to follow.
fn plan_redirect(
  request : Request,
  response : ResponseHead,
  followed~ : Int32,
  max_redirects~ : Int32,
  allow_downgrade~ : Bool,
  credential_headers~ : Array[String],
) -> Request? raise RedirectError {
  guard redirect_status(response.status) &&
    response.headers.get("location") is Some(location) else {
    return None
  }
  let (from, to) = redirect_target(request.url, location)
  if from.scheme == Some("https") &&
    to.scheme == Some("http") &&
    !allow_downgrade {
    raise Downgrade(location=to.to_string())
  }
  if followed >= max_redirects {
    raise TooManyRedirects(max=max_redirects, location=to.to_string())
  }
  let http_method = redirect_method(response.status, request.http_method)
  let drop_body = http_method != request.http_method
  if !drop_body && !request.body.is_replayable() {
    raise UnreplayableBody(location=to.to_string())
  }
  let headers = redirect_headers(
    request.headers,
    from~,
    to~,
    drop_body~,
    credential_headers~,
  )
  Some({
    http_method,
    url: to.without_fragment().to_string(),
    headers,
    body: if drop_body {
      Bytes(b"")
    } else {
      request.body
    },
  })
}

///|
/// Whether `status` is a redirect this step follows. 300 leaves the choice to
/// the user, 304 is a cache answer and 305 and 306 are retired (RFC 9110
/// §15.4).
fn redirect_status(status : Int32) -> Bool {
  status is (301 | 302 | 303 | 307 | 308)
}

///|
/// The method of the redirected request: 303 makes everything but HEAD a
/// GET, 301 and 302 make POST a GET, the rest keep theirs (Fetch, httpx).
fn redirect_method(status : Int32, http_method : String) -> String {
  let upper = http_method.to_upper()
  match status {
    303 if upper != "GET" && upper != "HEAD" => "GET"
    301 | 302 if upper == "POST" => "GET"
    _ => http_method
  }
}

///|
/// The request URL and the `Location` resolved against it, refused unless the
/// result is an absolute `http` or `https` URL with a host.
fn redirect_target(
  request_url : String,
  location : String,
) -> (Url, Url) raise RedirectError {
  let from = Url::parse(request_url) catch {
    Invalid(reason) =>
      raise BadLocation(location~, reason="request URL: " + reason)
  }
  guard from.scheme is Some("http" | "https") else {
    raise BadLocation(location~, reason="request URL is not absolute http(s)")
  }
  let to = from.resolve(
    Url::parse(location) catch {
      Invalid(reason) => raise BadLocation(location~, reason~)
    },
  )
  guard to.scheme is Some("http" | "https") else {
    raise BadLocation(location~, reason="not an http or https URL")
  }
  guard to.host is Some(host) && host != "" else {
    raise BadLocation(location~, reason="no host")
  }
  (from, to)
}

///|
/// The headers of the redirected request: without the body's headers when
/// the body is dropped, and without credentials when the origin changes,
/// except on a same-host upgrade from `http` to `https` on default ports.
fn redirect_headers(
  headers : Headers,
  from~ : Url,
  to~ : Url,
  drop_body~ : Bool,
  credential_headers~ : Array[String],
) -> Headers {
  let removed = []
  if drop_body {
    removed.push_iter(body_headers.iter())
  }
  if !from.same_origin(to) {
    removed.push("host")
    if !secure_upgrade(from, to) {
      removed.push_iter(sensitive_headers.iter())
      removed.push_iter(credential_headers.iter().map(name => name.to_lower()))
    }
  }
  Headers::from_array(
    headers.iter().filter(pair => !removed.contains(pair.0)).to_array(),
  )
}

///|
let body_headers : Array[String] = [
  "content-length", "content-type", "transfer-encoding", "content-encoding", "content-language",
  "content-location",
]

///|
let sensitive_headers : Array[String] = [
  "authorization", "cookie", "proxy-authorization",
]

///|
/// Whether `to` is `from` moved from `http` on port 80 to `https` on port 443
/// of the same host (httpx's `_is_https_redirect`).
fn secure_upgrade(from : Url, to : Url) -> Bool {
  from.host == to.host &&
  from.scheme == Some("http") &&
  from.port_or_default() == Some(80) &&
  to.scheme == Some("https") &&
  to.port_or_default() == Some(443)
}
