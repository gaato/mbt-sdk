///|
// JS Client is lazy: fetch establishes the connection in end_request. Fetch
// exposes network and malformed-response failures through the same rejection.
fn head_error(error : Error) -> @http.HttpError {
  @http.HttpError::Connect(error.to_string())
}
