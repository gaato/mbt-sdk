///|
/// Request authentication. Debug output always redacts credential values.
pub(all) enum Auth {
  NoAuth
  Bearer(String)
  Header(String, String)
}

///|
/// Redacted debug representation of authentication settings.
pub extend Auth with @debug.Debug::{to_repr}

///|
/// Formats authentication without exposing a bearer token or header value.
pub impl @debug.Debug for Auth with fn to_repr(self) {
  match self {
    NoAuth => @debug.Repr::ctor("NoAuth", [])
    Bearer(_) =>
      @debug.Repr::ctor("Bearer", [(None, @debug.Repr::literal("<redacted>"))])
    Header(name, _) =>
      @debug.Repr::ctor("Header", [
        (None, @debug.Repr::string(name)),
        (None, @debug.Repr::literal("<redacted>")),
      ])
  }
}

///|
/// Adds authentication only when the request has no header with the same name.
///
/// ```mbt check
/// test {
///   let request = @runtime.Bearer("secret").apply(@http.Request::get("/"))
///   assert_eq(request.headers.get("authorization"), Some("Bearer secret"))
/// }
/// ```
pub fn Auth::apply(self : Auth, request : @http.Request) -> @http.Request {
  match self {
    NoAuth => request
    Bearer(token) =>
      if request.headers.contains("authorization") {
        request
      } else {
        let result = request.body_bytes(request.body)
        result.headers.set("authorization", "Bearer " + token)
        result
      }
    Header(name, value) =>
      if request.headers.contains(name) {
        request
      } else {
        let result = request.body_bytes(request.body)
        result.headers.set(name, value)
        result
      }
  }
}
