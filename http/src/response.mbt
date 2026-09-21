///|
/// An HTTP response. Error status codes are ordinary responses.
///
/// ```mbt check
/// test {
///   let response : @http.Response = {
///     status: 200,
///     headers: @http.Headers::new(),
///     body: b"hello",
///   }
///   assert_eq(response.text(), "hello")
///   assert_true(response.is_success())
/// }
/// ```
pub(all) struct Response {
  status : Int
  headers : Headers
  body : Bytes
} derive(Eq, Debug)

///|
/// Compares all response fields.
pub extend Response with Eq::{equal, not_equal}

///|
/// Debug representation of a response.
pub extend Response with @debug.Debug::{to_repr}

///|
/// Strictly decodes the UTF-8 body, raising on malformed input.
pub fn Response::text(self : Response) -> String raise @utf8.Malformed {
  @utf8.decode(self.body)
}

///|
/// Parses the strictly decoded body, raising on malformed UTF-8 or invalid JSON.
pub fn Response::json(self : Response) -> Json raise {
  @json.parse(self.text())
}

///|
/// Reports whether the status is in the inclusive range 200 through 299.
pub fn Response::is_success(self : Response) -> Bool {
  self.status >= 200 && self.status <= 299
}

///|
/// Status and headers available before consuming a streamed body.
pub(all) struct ResponseHead {
  status : Int
  headers : Headers
} derive(Eq, Debug)

///|
/// Compares status and headers.
pub extend ResponseHead with Eq::{equal, not_equal}

///|
/// Debug representation of a response head.
pub extend ResponseHead with @debug.Debug::{to_repr}
