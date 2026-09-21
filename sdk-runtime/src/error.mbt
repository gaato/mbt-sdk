///|
/// Failures distinguished by transport, HTTP status, decoding, or configuration.
pub(all) suberror SdkError {
  Transport(@http.HttpError)
  Status(status~ : Int, headers~ : @http.Headers, body~ : Bytes)
  RateLimited(retry_after_ms~ : Int?, headers~ : @http.Headers, body~ : Bytes)
  Decode(message~ : String, body~ : Bytes)
  Config(String)
} derive(Debug)

///|
/// Formats the classified failure for debugging.
pub extend SdkError with @debug.Debug::{to_repr}

///|
/// Returns successful responses unchanged and classifies all other statuses.
///
/// ```mbt check
/// test {
///   let response : @http.Response = {
///     status: 204,
///     headers: @http.Headers::new(),
///     body: b"",
///   }
///   assert_eq(@runtime.classify(response), response)
///   let error = @runtime.Transport(@http.Timeout(500))
///   assert_eq(error.status(), None)
///   assert_true(error.is_retryable())
/// }
/// ```
pub fn classify(
  response : @http.Response,
  now_unix_ms? : Int64,
) -> @http.Response raise SdkError {
  if response.status >= 200 && response.status <= 299 {
    response
  } else if response.status == 429 {
    raise RateLimited(
      retry_after_ms=retry_after_ms(response.headers, now_unix_ms?),
      headers=response.headers,
      body=response.body,
    )
  } else {
    raise Status(
      status=response.status,
      headers=response.headers,
      body=response.body,
    )
  }
}

///|
/// Returns an HTTP status only for failures with an HTTP status.
pub fn SdkError::status(self : SdkError) -> Int? {
  match self {
    Status(status~, ..) => Some(status)
    RateLimited(..) => Some(429)
    _ => None
  }
}

///|
/// Reports transient failures; request idempotency remains the caller's concern.
pub fn SdkError::is_retryable(self : SdkError) -> Bool {
  match self {
    Transport(Connect(_) | Timeout(_)) | RateLimited(..) => true
    Status(status=408 | 409 | 500 | 502 | 503 | 504, ..) => true
    _ => false
  }
}
