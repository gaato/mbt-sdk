///|
// Native/Wasm Client completes DNS, TCP and TLS in its constructor, writes the
// request as it is given, and parses the response itself, so every phase is
// seen as it happens.
fn reported_phase(phase : @http.Phase) -> @http.Phase {
  phase
}

///|
// The parser's refusals are malformed messages; everything else that fails
// after connecting (a reset, an end of stream before the message ended, a TLS
// alert) is the connection's.
fn is_malformed(error : Error) -> Bool {
  error
  is (@ahttp.HttpProtocolError::BadRequest
  | @ahttp.HttpProtocolError::HttpVersionNotSupported(_)
  | @ahttp.HttpProtocolError::NotImplemented)
}
