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

///|
// moonbitlang/async refuses a non-2xx answer to the tunnel's `CONNECT` with
// `ProxyError`, before the origin is reached.
fn proxy_refusal(error : Error) -> @http.HttpError? {
  guard error is @ahttp.ProxyError::ProxyError(response) else { return None }
  Some(
    Proxy(
      status=response.code,
      message="the proxy refused the tunnel: \{response.code} \{response.reason}",
    ),
  )
}
