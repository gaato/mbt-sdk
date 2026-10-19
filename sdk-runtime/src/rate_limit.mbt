///|
/// Remaining requests and the Unix millisecond instant when a window resets.
pub(all) struct RateLimitState {
  remaining : Int32
  reset_at_unix_ms : Int64
} derive(Eq, Debug)

///|
/// Equality for rate-limit states.
pub extend RateLimitState with Eq::{equal, not_equal}

///|
/// Debug representation of rate-limit states.
pub extend RateLimitState with @debug.Debug::{to_repr}

///|
/// A per-bucket admission policy updated from HTTP responses.
///
/// `acquire` and `release` come in pairs: the client calls `release` exactly
/// once for every `acquire` that returned, with the response's status and
/// headers, or with status `0` and no headers when the attempt produced no
/// response (a transport failure or a cancellation). A limiter that holds
/// per-bucket state across the exchange, such as a gate that serialises one
/// bucket, relies on that pairing; a stateless window limiter ignores the
/// status-`0` calls.
///
/// A cancelled task still gets its `release`, but inside cancellation any
/// further asynchronous work is cut short, so an implementation that talks to
/// another process must recover on its own if that call does not complete
/// (dropping its connection so the peer can clean up, for example).
pub(open) trait RateLimiter {
  /// Waits until one request may enter a bucket. `global_exempt` marks a
  /// request that does not count toward an account-wide limit; a limiter
  /// without such a limit ignores it. An error (a limiter in another process
  /// that cannot be reached, say) fails the request before it is sent.
  async fn acquire(Self, String, global_exempt~ : Bool) -> Unit
  /// Reports the outcome of the request admitted by the matching `acquire`.
  /// Status `0` means no response arrived. An error raised on the success
  /// path reaches the caller; one raised while the attempt is already failing
  /// is dropped.
  async fn release(Self, String, status~ : Int32, headers~ : @http.Headers) -> Unit
}

///|
/// A limiter that never delays requests and ignores releases.
pub struct NoLimiter {}

///|
/// Creates a limiter that admits every request.
pub fn NoLimiter::new() -> NoLimiter {
  NoLimiter::{ }
}

///|
/// Explicit no-op limiter methods.
pub extend NoLimiter with RateLimiter::{acquire, release}

///|
/// Admits immediately.
pub impl RateLimiter for NoLimiter with fn acquire(
  _self,
  _bucket,
  global_exempt~,
) {
  ignore(global_exempt)
}

///|
/// Ignores response state.
pub impl RateLimiter for NoLimiter with fn release(
  _self,
  _bucket,
  status~,
  headers~,
) {
  ignore(status)
  ignore(headers)
}

///|
/// An account-wide admission window counted across buckets: at most `limit`
/// admissions in each `window_ms`. Both must be positive; a window with a
/// non-positive limit or length imposes no limit, since it would otherwise
/// block forever or reset on every admission.
pub(all) struct GlobalWindow {
  limit : Int32
  window_ms : Int32
} derive(Eq, Debug)

///|
/// Equality for global windows.
pub extend GlobalWindow with Eq::{equal, not_equal}

///|
/// Debug representation of global windows.
pub extend GlobalWindow with @debug.Debug::{to_repr}

///|
/// How far apart one group's admissions must be. `WindowLimiter::new(pace?)`
/// maps each bucket to its group; admissions in a group start at least
/// `min_interval_ms` apart, whatever the server's window says. A non-positive
/// interval imposes no spacing.
pub(all) struct Pace {
  group : String
  min_interval_ms : Int32
} derive(Eq, Debug)

///|
/// Equality for paces.
pub extend Pace with Eq::{equal, not_equal}

///|
/// Debug representation of paces.
pub extend Pace with @debug.Debug::{to_repr}

///|
/// What a 429 response does to a `WindowLimiter`. Each case applies the
/// Retry-After delay (or the configured default) differently.
#non_exhaustive
pub(all) enum LimitScope {
  /// The request's bucket is empty until the delay ends; the account-wide
  /// block is unchanged. The default.
  Bucket
  /// Every non-exempt request waits until the delay ends (extending, never
  /// shortening, the account-wide block); the bucket keeps its parsed state.
  Global
  /// A limit shared with other clients ran out: the bucket keeps only the
  /// state parsed from the headers, as for any other response, and is not
  /// emptied.
  Shared
  /// The response changes nothing: no state is recorded and no block is set.
  Ignore
} derive(Eq, Debug)

///|
/// Equality for limit scopes.
pub extend LimitScope with Eq::{equal, not_equal}

///|
/// Debug representation of limit scopes.
pub extend LimitScope with @debug.Debug::{to_repr}

///|
/// One pace group's gate and the tasks that hold it or wait on it. The limiter
/// drops the entry once both counts are zero, so a later caller makes a fresh
/// gate only when no task can still touch this one.
priv struct BucketGate {
  gate : &@sync.Gate
  mut holders : Int32
  mut waiters : Int32
}

///|
/// The fewest recorded states at which `release` sweeps out expired ones.
let states_sweep_floor : Int32 = 64

///|
/// The longest a recorded state outlives its reset when the map stops
/// growing: `release` also sweeps once this long has passed since the last
/// sweep.
let states_sweep_interval_ms : Int64 = 60_000L

///|
/// A mutable per-bucket fixed-window limiter driven by an injected clock.
pub struct WindowLimiter {
  priv clock : &@clock.Clock
  priv parse : (@http.Headers, Int64) -> RateLimitState?
  priv states : Map[String, RateLimitState]
  priv mut states_sweep_at : Int32
  priv mut states_swept_at_ms : Int64
  priv gate : (() -> &@sync.Gate)?
  priv gates : Map[String, BucketGate]
  priv pace : (String) -> Pace
  priv server_key : ((String, @http.Headers) -> String?)?
  priv aliases : Map[String, String]
  priv next_admit_at : Map[String, Int64]
  priv scope : (Int32, @http.Headers) -> LimitScope
  priv global : GlobalWindow?
  priv default_retry_after_ms : Int32?
  priv mut global_window_start : Int64?
  priv mut global_count : Int32
  priv mut global_blocked_until : Int64?
}

///|
/// Creates a limiter using an API-specific response-header parser.
///
/// `pace` maps a bucket to its pace group, whose admissions start at least
/// `min_interval_ms` apart; by default each bucket is its own group with no
/// spacing. It must be pure: `acquire` and `release` each call it and must
/// get the same group for the same bucket.
/// `gate` creates a pace group's gate, held from `acquire` until the paired
/// release, so the buckets of one group are serialised together; a group
/// nobody holds or waits on forgets its gate and gets a new one on its next
/// acquire.
/// `server_key` reads, from a response's headers, the key under which the server
/// counts the bucket (several buckets may share one server window). Once it
/// names a key, the bucket's state is recorded and looked up under that key
/// until a later response names another one or the key's state expires; the
/// gate and the pace group stay the bucket's own.
/// `scope` says what a 429 does (`LimitScope`); it is asked only about 429
/// responses, with their status and headers. By default a 429 empties its
/// bucket for its Retry-After, or blocks every bucket when `global_block`
/// says the 429 is account-wide. `global_block` is kept for existing callers
/// and is ignored when `scope` is given.
/// `global` limits non-exempt admissions across buckets; one with a
/// non-positive limit or length is ignored.
/// `default_retry_after_ms` supplies a delay when a 429 has no Retry-After.
/// Negative fallback delays and pace intervals are treated as zero.
/// A response's parsed reset and Retry-After count only up to one hour ahead,
/// so no server can hold a bucket, or every request, longer than that.
pub fn WindowLimiter::new(
  clock : &@clock.Clock,
  parse : (@http.Headers, Int64) -> RateLimitState?,
  gate? : () -> &@sync.Gate,
  pace? : (String) -> Pace,
  server_key? : (String, @http.Headers) -> String?,
  scope? : (Int32, @http.Headers) -> LimitScope,
  global? : GlobalWindow,
  global_block? : (@http.Headers) -> Bool,
  default_retry_after_ms? : Int32,
) -> WindowLimiter {
  {
    clock,
    parse,
    states: Map([]),
    states_sweep_at: states_sweep_floor,
    states_swept_at_ms: clock.now_unix_ms(),
    gate,
    gates: Map([]),
    pace: match pace {
      Some(pace) => pace
      None => bucket => { group: bucket, min_interval_ms: 0, }
    },
    server_key,
    aliases: Map([]),
    next_admit_at: Map([]),
    scope: match (scope, global_block) {
      (Some(scope), _) => scope
      (None, Some(is_global)) =>
        (_, headers) => if is_global(headers) { Global } else { Bucket }
      (None, None) => (_, _) => Bucket
    },
    global: match global {
      Some(window) if window.limit > 0 && window.window_ms > 0 => Some(window)
      _ => None
    },
    default_retry_after_ms,
    global_window_start: None,
    global_count: 0,
    global_blocked_until: None,
  }
}

///|
async fn WindowLimiter::wait_for_global(self : WindowLimiter) -> Unit {
  for ;; {
    let step = global_step(
      self.clock.now_unix_ms(),
      blocked_until=self.global_blocked_until,
      window=self.global,
      start=self.global_window_start,
      count=self.global_count,
    )
    match step {
      Pass => return
      Admit(start~, count~) => {
        self.global_window_start = Some(start)
        self.global_count = count
        return
      }
      Wait(delay) => self.clock.sleep(delay)
    }
  }
}

///|
/// Returns the pace group's gate, counting the caller as a waiter on it. The
/// count is taken before any suspension, so the entry outlives every task that
/// might still acquire or release this gate.
fn WindowLimiter::join_gate(
  self : WindowLimiter,
  group : String,
  make : () -> &@sync.Gate,
) -> BucketGate {
  let entry = match self.gates.get(group) {
    Some(entry) => entry
    None => {
      let entry = { gate: make(), holders: 0, waiters: 0, }
      self.gates[group] = entry
      entry
    }
  }
  entry.waiters += 1
  entry
}

///|
/// Stops counting the caller on the pace group's gate, returning its slot when
/// `holding`, and forgets the gate once nobody holds it or waits on it.
fn WindowLimiter::leave_gate(
  self : WindowLimiter,
  group : String,
  holding~ : Bool,
) -> Unit {
  guard self.gates.get(group) is Some(entry) else { return }
  if holding {
    guard entry.holders > 0 else { return }
    entry.holders -= 1
    entry.gate.release()
  } else {
    guard entry.waiters > 0 else { return }
    entry.waiters -= 1
  }
  if entry.holders == 0 && entry.waiters == 0 {
    self.gates.remove(group)
  }
}

///|
/// The number of entries a sweep can drop: states, aliases and pace deadlines.
fn WindowLimiter::swept_entries(self : WindowLimiter) -> Int32 {
  self.states.length() + self.aliases.length() + self.next_admit_at.length()
}

///|
/// Drop states whose reset has passed, the aliases that point at a key with no
/// state left, and pace deadlines already behind `now`, each time those maps
/// together have doubled since the last sweep (and hold at least
/// `states_sweep_floor` entries), so buckets that are never seen again cost
/// amortised constant work, and at least every `states_sweep_interval_ms`, so
/// a burst's expired entries do not stay once traffic returns to a few
/// buckets. Every release checks, whether or not its response records a
/// state.
fn WindowLimiter::sweep_states(self : WindowLimiter, now : Int64) -> Unit {
  guard self.swept_entries() >= self.states_sweep_at ||
    now - self.states_swept_at_ms >= states_sweep_interval_ms else {
    return
  }
  let expired = []
  for key, recorded in self.states {
    if recorded.reset_at_unix_ms <= now {
      expired.push(key)
    }
  }
  for key in expired {
    self.states.remove(key)
  }
  let orphaned = []
  for bucket, key in self.aliases {
    if !self.states.contains(key) {
      orphaned.push(bucket)
    }
  }
  for bucket in orphaned {
    self.aliases.remove(bucket)
  }
  let passed = []
  for group, at in self.next_admit_at {
    if at <= now {
      passed.push(group)
    }
  }
  for group in passed {
    self.next_admit_at.remove(group)
  }
  self.states_sweep_at = (self.swept_entries() * 2).max(states_sweep_floor)
  self.states_swept_at_ms = now
}

///|
/// The key a bucket's state is recorded under: the server key its last
/// response named through `server_key`, or the bucket itself.
fn WindowLimiter::resolve(self : WindowLimiter, bucket : String) -> String {
  self.aliases.get(bucket).unwrap_or(bucket)
}

///|
/// Explicit fixed-window limiter methods.
pub extend WindowLimiter with RateLimiter::{acquire, release}

///|
/// Returns the currently recorded state for a bucket, looked up under the key
/// its last response named through `server_key`, if any.
pub fn WindowLimiter::state(
  self : WindowLimiter,
  bucket : String,
) -> RateLimitState? {
  self.states.get(self.resolve(bucket))
}

///|
/// Waits for the account-wide window, then the pace group's gate, then the
/// group's spacing and the bucket's window. Rechecks both after every sleep
/// because another task may update them; the check that admits and the
/// group's next admission time it records happen without suspending between
/// them, so two tasks never both pass one deadline.
pub impl RateLimiter for WindowLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  if !global_exempt {
    self.wait_for_global()
  }
  let { group, min_interval_ms, } = (self.pace)(bucket)
  let entry = self.gate.map(make => self.join_gate(group, make))
  let mut holding = false
  errdefer self.leave_gate(group, holding~)
  if entry is Some(entry) {
    // A cancelled `acquire` unwinds without a slot; one that returns holds it.
    entry.gate.acquire()
    entry.waiters -= 1
    entry.holders += 1
    holding = true
  }
  for ;; {
    let now = self.clock.now_unix_ms()
    let paced = pace_step(self.next_admit_at.get(group), now)
    if paced > 0 {
      self.clock.sleep(paced)
      continue
    }
    // Resolved on every pass: a response may name the key while this waits.
    let key = self.resolve(bucket)
    match bucket_step(self.states.get(key), now) {
      Admit => ()
      Expired => self.states.remove(key)
      Consume(state) => self.states[key] = state
      Wait(delay) => {
        self.clock.sleep(delay)
        continue
      }
    }
    if min_interval_ms > 0 {
      self.next_admit_at[group] = saturating_add_ms(now, min_interval_ms)
    }
    return
  }
}

///|
/// The furthest ahead a response may move a bucket's reset or the account-wide
/// block: one hour, the longest window among the APIs served here (GitHub's
/// hourly quota; Discord resets in seconds, OpenAI per minute). Without it a
/// reset or Retry-After far in the future would keep a state, and make every
/// acquisition wait, for as long as the server said.
let max_server_wait_ms : Int32 = 3_600_000

///|
/// Pulls a parsed reset back to at most `max_server_wait_ms` after `now`.
fn clamp_server_reset(state : RateLimitState, now : Int64) -> RateLimitState {
  let horizon = saturating_add_ms(now, max_server_wait_ms)
  if state.reset_at_unix_ms > horizon {
    { ..state, reset_at_unix_ms: horizon, }
  } else {
    state
  }
}

///|
/// Replaces parsed state; a 429 Retry-After takes precedence over that parser
/// as the limiter's `scope` says. A key named through `server_key` is remembered
/// for the bucket and the state recorded under it.
/// An attempt without a response (status `0`) leaves the window unchanged.
/// Both the parsed reset and the Retry-After delay are clamped to one hour
/// ahead, however far the server puts them.
pub impl RateLimiter for WindowLimiter with fn release(
  self,
  bucket,
  status~,
  headers~,
) {
  defer self.leave_gate((self.pace)(bucket).group, holding=true)
  let now_unix_ms = self.clock.now_unix_ms()
  self.sweep_states(now_unix_ms)
  if status == 0 {
    return
  }
  let key = match self.server_key {
    Some(server_key) =>
      match server_key(bucket, headers) {
        Some(key) if key == bucket => {
          self.aliases.remove(bucket)
          key
        }
        Some(key) => {
          self.aliases[bucket] = key
          key
        }
        None => self.resolve(bucket)
      }
    None => bucket
  }
  let effect = release_effect(
    status,
    parsed=(self.parse)(headers, now_unix_ms).map(state => {
      clamp_server_reset(state, now_unix_ms)
    }),
    delay_ms=match @http.retry_after_ms(headers, now_unix_ms~) {
      Some(ms) => Some(ms.min(max_server_wait_ms))
      None => self.default_retry_after_ms
    },
    scope=if status == 429 { (self.scope)(status, headers) } else { Bucket },
    blocked_until=self.global_blocked_until,
    now=now_unix_ms,
  )
  if effect.record is Some(state) {
    self.states[key] = state
  }
  self.global_blocked_until = effect.blocked_until
}

///|
/// Builds a parser for conventional remaining/reset response headers.
pub fn rate_limit_headers(
  remaining~ : String,
  reset_after_seconds? : String,
  reset_unix_seconds? : String,
) -> (@http.Headers, Int64) -> RateLimitState? {
  (headers, now) => {
    guard headers.get(remaining) is Some(raw_remaining) else { return None }
    guard parse_nonnegative_int(raw_remaining) is Some(left) else {
      return None
    }
    let reset = match reset_after_seconds {
      Some(name) =>
        match headers.get(name) {
          Some(value) =>
            decimal_seconds_ms(value).map(ms => saturating_add_i64(now, ms))
          None => None
        }
      None => None
    }
    let reset = match reset {
      Some(value) => Some(value)
      None =>
        match reset_unix_seconds {
          Some(name) =>
            match headers.get(name) {
              Some(value) => decimal_seconds_ms(value)
              None => None
            }
          None => None
        }
    }
    reset.map(reset_at_unix_ms => { remaining: left, reset_at_unix_ms, })
  }
}

///|
fn parse_nonnegative_int(value : String) -> Int32? {
  let value = value.trim()
  if value.is_empty() {
    return None
  }
  let mut result = 0
  for c in value {
    guard c >= '0' && c <= '9' else { return None }
    let digit = c.to_int() - 48
    if result > (2147483647 - digit) / 10 {
      return None
    }
    result = result * 10 + digit
  }
  Some(result)
}

///|
fn decimal_seconds_ms(value : String) -> Int64? {
  let value = value.trim()
  let mut whole = 0L
  let mut fraction = 0L
  let mut weight = 100L
  let mut dot = false
  let mut before = 0
  let mut after = 0
  for c in value {
    if c == '.' && !dot {
      dot = true
    } else if c >= '0' && c <= '9' {
      let digit = (c.to_int() - 48).to_int64()
      if dot {
        after += 1
        if weight > 0L {
          fraction += digit * weight
          weight /= 10L
        }
      } else {
        before += 1
        whole = if whole > (9223372036854775807L - digit) / 10L {
          9223372036854775807L
        } else {
          whole * 10L + digit
        }
      }
    } else {
      return None
    }
  }
  if before == 0 || (dot && after == 0) {
    return None
  }
  if whole > (9223372036854775807L - fraction) / 1000L {
    Some(9223372036854775807L)
  } else {
    Some(whole * 1000L + fraction)
  }
}

///|
fn saturating_add_ms(now : Int64, milliseconds : Int32) -> Int64 {
  saturating_add_i64(now, milliseconds.to_int64())
}

///|
fn saturating_add_i64(left : Int64, right : Int64) -> Int64 {
  if right > 0L && left > 9223372036854775807L - right {
    9223372036854775807L
  } else {
    left + right
  }
}
