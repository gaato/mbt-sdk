///|
/// A time limit injected by an async runtime (such as `gaato/http-async`)
/// so sans-IO code can bound a piece of work without importing that
/// runtime. Trait methods cannot be generic, so `f` returns nothing: a caller
/// that wants a result writes it into a cell `f` captures.
pub(open) trait Timer {
  /// Runs `f` for at most `ms` milliseconds: true if it finished, false if
  /// time ran out first (`f` is cancelled). `ms <= 0` returns false without
  /// starting `f`.
  async fn within(Self, Int32, async () -> Unit noraise) -> Bool noraise
}
