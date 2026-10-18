///|
/// A per-exchange deadline: the whole buffered exchange, or only the response
/// head for a streaming exchange. Expiry raises `Timeout(phase=Unknown,
/// ms=timeout_ms)`, since the deadline cannot see which phase the inner
/// transport was in; the inner transport's own failures pass through.
pub struct DeadlineTransport {
  priv inner : &@http.Transport
  priv timeout_ms : Int32
}

///|
/// Wraps a transport with a deadline; nonpositive deadlines expire immediately.
pub fn DeadlineTransport::new(
  inner : &@http.Transport,
  timeout_ms~ : Int32,
) -> DeadlineTransport {
  { inner, timeout_ms, }
}

///|
/// Explicit transport methods with per-exchange deadlines.
pub extend DeadlineTransport with @http.Transport::{send, send_stream}

///|
/// Sends the entire buffered exchange within the deadline.
pub impl @http.Transport for DeadlineTransport with fn send(self, request) {
  bounded(self.timeout_ms, () => self.inner.send(request))
}

///|
/// Waits for the response head within the deadline, leaving its stream unbounded.
pub impl @http.Transport for DeadlineTransport with fn send_stream(
  self,
  request,
) {
  bounded(self.timeout_ms, () => self.inner.send_stream(request))
}

///|
/// Runs `f` under one deadline. Expiry surfaces as `Timeout(phase=Unknown,
/// ms)`; every other failure is narrowed to `HttpError`. Cancellation is not an
/// `Error` in moonbitlang/async, so `catch` never sees it and it propagates
/// untouched.
async fn[X] bounded(
  ms : Int32,
  f : async () -> X raise @http.HttpError,
) -> X raise @http.HttpError {
  let expired = @http.HttpError::Timeout(phase=Unknown, ms~)
  if ms <= 0 {
    raise expired
  }
  @async.with_timeout(ms, () => f(), error=expired) catch {
    error => raise failure(Unknown, error)
  }
}
