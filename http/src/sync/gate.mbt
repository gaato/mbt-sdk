///|
/// An admission gate injected by an async runtime so sans-IO code can hold a
/// slot across an exchange without importing that runtime.
pub(open) trait Gate {
  /// Waits for a slot; runtime cancellation propagates as a signal, not an Error.
  async fn acquire(Self) -> Unit noraise
  /// Returns one slot taken by a successful acquire.
  fn release(Self) -> Unit
}
