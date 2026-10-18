///|
// JS Client is fetch: its constructor only stores the origin and writes only
// buffer the body, so connecting, sending and waiting for the head all happen
// in the one fetch call made for the head. Fetch reports a DNS failure, a
// refused or reset connection and a malformed response alike, as a TypeError,
// so a failure or timeout there is in an Unknown phase, and never Connect: the
// request may have reached the server. Body reads are seen as they happen.
fn reported_phase(phase : @http.Phase) -> @http.Phase {
  match phase {
    Head => Unknown
    other => other
  }
}

///|
// Fetch does not tell a malformed response from a network failure.
fn is_malformed(_error : Error) -> Bool {
  false
}
