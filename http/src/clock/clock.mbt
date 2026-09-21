///|
/// A source of wall-clock time and nonblocking delays for sans-IO clients.
pub(open) trait Clock {
  /// Sleeps for `milliseconds`; nonpositive values return immediately.
  async fn sleep(Self, Int) -> Unit noraise
  /// Returns milliseconds since the Unix epoch.
  fn now_unix_ms(Self) -> Int64
}
