///|
// Native/Wasm Client completes DNS/TCP/TLS in its constructor. Failures after that
// point belong to sending or parsing the HTTP exchange.
fn head_error(error : Error) -> @http.HttpError {
  @http.HttpError::Protocol(error.to_string())
}
