///|
/// Returns `request` with the jar's `Cookie` header for its URL added, or
/// `request` itself when no cookie matches or it already carries a `Cookie`
/// header, which is left exactly as the caller set it. The headers are
/// copied, so `request` is not changed.
///
/// Middleware does not wrap `Transport::send_stream`; a streaming caller
/// sends `jar.attach(request)` and then calls
/// `jar.store(head.headers, request.url)` with the `ResponseHead` it gets.
pub fn CookieJar::attach(
  self : CookieJar,
  request : @http.Request,
) -> @http.Request {
  if request.headers.contains("cookie") {
    return request
  }
  match self.header_for(request.url) {
    Some(value) => request.header("Cookie", value)
    None => request
  }
}

///|
/// A middleware step that sends `jar`'s cookies with each request (see
/// `CookieJar::attach`) and stores the `Set-Cookie` headers of its response.
/// Nothing is stored when the request fails.
///
/// Place it inside the redirect step, between `@http.redirects` and the
/// transport: `@http.send_with(transport, [@http.redirects(),
/// @cookie.cookies(jar)], request)`. The redirect step then sends every hop
/// through it, so each hop's `Set-Cookie` is stored before the next hop is
/// sent and each hop carries the cookies of its own URL. Placed outside, it
/// would see only the first URL and the final response: cookies set by an
/// intermediate response would be lost, and the first URL's cookies would
/// look like a header the caller set, kept on same-origin hops.
///
/// ```mbt check
/// test {
///   let jar = @cookie.CookieJar::new(@mock.FakeClock::new())
///   let _ : @http.Middleware = @cookie.cookies(jar)
/// }
/// ```
pub fn cookies(jar : CookieJar) -> @http.Middleware {
  (request, next) => {
    let response = next(jar.attach(request))
    jar.store(response.headers, request.url)
    response
  }
}
