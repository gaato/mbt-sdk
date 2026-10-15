///|
/// A per-exchange deadline: the whole buffered exchange, or only the response
/// head for a streaming exchange. Expiry raises HttpError::Timeout(timeout_ms).
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
