///|
/// The time limits of an exchange, in milliseconds. `total` bounds the
/// exchange as a whole; the others bound one phase each, `read` the head and
/// every body read separately.
priv struct Timeouts {
  total : Int32
  pool : Int32
  connect : Int32
  write : Int32
  read : Int32
}

///|
/// The limit of one phase.
fn Timeouts::of(self : Timeouts, phase : @http.Phase) -> Int32 {
  match phase {
    Pool => self.pool
    Dial => self.connect
    Write => self.write
    Head | Body | Unknown => self.read
  }
}

///|
/// How long a phase may run, and the limit to report when it runs out: the
/// phase's own `limit`, or the `remaining` time of an exchange limited to
/// `total` when that ends first. A nonpositive budget has already run out.
fn phase_budget(
  limit : Int32,
  total~ : Int32,
  remaining~ : Int64?,
) -> (Int32, Int32) {
  match remaining {
    Some(left) if left < limit.to_int64() => (left.max(0L).to_int(), total)
    _ => (limit, limit)
  }
}

///|
/// Runs the phases of one exchange against its limits on `clock`. `deadline`
/// is when the whole exchange must be done, or `None` for a stream's body
/// reads, which only the read limit bounds.
priv struct PhaseTimer {
  clock : &@clock.Clock
  limits : Timeouts
  deadline : Int64?
}

///|
/// A timer for an exchange starting now, due within `limits.total`.
fn PhaseTimer::exchange(clock : &@clock.Clock, limits : Timeouts) -> PhaseTimer {
  {
    clock,
    limits,
    deadline: Some(clock.now_unix_ms() + limits.total.to_int64()),
  }
}

///|
/// A timer for the body reads of a stream, each bounded by `limits.read`.
fn PhaseTimer::stream(clock : &@clock.Clock, limits : Timeouts) -> PhaseTimer {
  { clock, limits, deadline: None, }
}

///|
/// Runs `f` as `phase`. A limit that runs out cancels `f` and raises
/// `Timeout` with the phase the platform can see and the limit that expired;
/// one already spent raises without starting `f`. Failures of `f` become an
/// `HttpError` through `failure`. Cancellation from outside is not an
/// `Error`, so it propagates untouched.
async fn[X] PhaseTimer::run(
  self : PhaseTimer,
  phase : @http.Phase,
  f : async () -> X,
) -> X raise @http.HttpError {
  let (budget, limit) = phase_budget(
    self.limits.of(phase),
    total=self.limits.total,
    remaining=self.deadline.map(at => at - self.clock.now_unix_ms()),
  )
  let expired = @http.HttpError::Timeout(phase=reported_phase(phase), ms=limit)
  if budget <= 0 {
    raise expired
  }
  let outcome = with_timeout_opt(self.clock, budget, f) catch {
    error => raise failure(phase, error)
  }
  match outcome {
    Some(value) => value
    None => raise expired
  }
}
