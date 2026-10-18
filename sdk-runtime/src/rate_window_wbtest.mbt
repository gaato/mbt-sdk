///|
let max_ms : Int64 = 9223372036854775807L

///|
fn global_step_label(step : GlobalStep) -> String {
  match step {
    Pass => "pass"
    Admit(start~, count~) => "admit start=\{start} count=\{count}"
    Wait(delay) => "wait \{delay}"
  }
}

///|
fn bucket_step_label(step : BucketStep) -> String {
  match step {
    Admit => "admit"
    Expired => "expired"
    Consume(state) =>
      "consume remaining=\{state.remaining} reset=\{state.reset_at_unix_ms}"
    Wait(delay) => "wait \{delay}"
  }
}

///|
test "global_step opens, counts, resets and waits out the window" {
  let window = Some({ limit: 2, window_ms: 1000, })
  let rows : Array[
    (String, Int64, Int64?, GlobalWindow?, Int64?, Int32, String),
  ] = [
    ("no window", 1000L, None, None, None, 0, "pass"),
    (
      "first admission",
      1000L,
      None,
      window,
      None,
      0,
      "admit start=1000 count=1",
    ),
    (
      "count below the limit",
      1500L,
      None,
      window,
      Some(1000L),
      1,
      "admit start=1000 count=2",
    ),
    ("count at the limit", 1500L, None, window, Some(1000L), 2, "wait 500"),
    ("one before the end", 1999L, None, window, Some(1000L), 2, "wait 1"),
    (
      "now at the end resets",
      2000L,
      None,
      window,
      Some(1000L),
      2,
      "admit start=2000 count=1",
    ),
    (
      "block ending now admits",
      1000L,
      Some(1000L),
      window,
      None,
      0,
      "admit start=1000 count=1",
    ),
    (
      "block ahead waits despite room",
      1000L,
      Some(1200L),
      window,
      Some(1000L),
      0,
      "wait 200",
    ),
    (
      "block ahead without a window",
      1000L,
      Some(1500L),
      None,
      None,
      0,
      "wait 500",
    ),
    (
      "end saturates near the maximum",
      max_ms - 5L,
      None,
      window,
      Some(max_ms - 10L),
      2,
      "wait 5",
    ),
    (
      "maximum instant reaches the saturated end",
      max_ms,
      None,
      window,
      Some(max_ms - 10L),
      2,
      "admit start=\{max_ms} count=1",
    ),
    (
      "negative clock with a saturated block",
      -1000L,
      Some(max_ms),
      window,
      None,
      0,
      "wait 2147483647",
    ),
  ]
  for row in rows {
    let (label, now, blocked_until, window, start, count, expected) = row
    assert_eq(
      global_step_label(
        global_step(now, blocked_until~, window~, start~, count~),
      ),
      expected,
      msg=label,
    )
  }
}

///|
test "bucket_step admits, consumes, expires and waits" {
  let rows : Array[(String, RateLimitState?, Int64, String)] = [
    ("no state", None, 1000L, "admit"),
    (
      "now at the reset",
      Some({ remaining: 0, reset_at_unix_ms: 2000L, }),
      2000L,
      "expired",
    ),
    (
      "last request left",
      Some({ remaining: 1, reset_at_unix_ms: 2000L, }),
      1999L,
      "consume remaining=0 reset=2000",
    ),
    (
      "negative instants",
      Some({ remaining: 3, reset_at_unix_ms: -500L, }),
      -1000L,
      "consume remaining=2 reset=-500",
    ),
    (
      "none left",
      Some({ remaining: 0, reset_at_unix_ms: 2000L, }),
      1000L,
      "wait 1000",
    ),
    (
      "longer than the longest sleep",
      Some({ remaining: 0, reset_at_unix_ms: max_ms, }),
      0L,
      "wait 2147483647",
    ),
    (
      // The span overflows Int64; wrapped and truncated it is a zero sleep,
      // so the wait would spin.
      "negative clock with a saturated reset",
      Some({ remaining: 0, reset_at_unix_ms: max_ms, }),
      -1L,
      "wait 2147483647",
    ),
  ]
  for row in rows {
    let (label, state, now, expected) = row
    assert_eq(bucket_step_label(bucket_step(state, now)), expected, msg=label)
  }
}

///|
test "delay_until clamps to the longest sleep and never wraps" {
  let rows : Array[(Int64, Int64, Int32)] = [
    (1500L, 1000L, 500),
    (1000L, 1000L, 0),
    (900L, 1000L, 0),
    (-1000L, -3000L, 2000),
    (2147483647L, 0L, 2147483647),
    (2147483648L, 0L, 2147483647),
    (max_ms, 0L, 2147483647),
    (max_ms, -1L, 2147483647),
    (max_ms, -9223372036854775807L - 1L, 2147483647),
  ]
  for row in rows {
    let (until, now, expected) = row
    assert_eq(
      delay_until(until, now),
      expected,
      msg="until=\{until} now=\{now}",
    )
  }
}

///|
test "release_effect records parsed state and applies 429 delays" {
  let parsed = Some({ remaining: 3, reset_at_unix_ms: 5000L, })
  let rows : Array[
    (
      String,
      Int32,
      RateLimitState?,
      Int32?,
      Bool,
      Int64?,
      Int64,
      RateLimitState?,
      Int64?,
    ),
  ] = [
    ("no response", 0, None, Some(1000), true, None, 1000L, None, None),
    (
      "success records parsed",
      200,
      parsed,
      None,
      false,
      None,
      1000L,
      parsed,
      None,
    ),
    (
      "success ignores a delay",
      200,
      parsed,
      Some(1000),
      true,
      Some(1500L),
      1000L,
      parsed,
      Some(1500L),
    ),
    (
      "success without parsed state",
      200,
      None,
      None,
      false,
      None,
      1000L,
      None,
      None,
    ),
    (
      "server error ignores a delay",
      503,
      parsed,
      Some(1000),
      false,
      None,
      1000L,
      parsed,
      None,
    ),
    (
      "429 delay overrides parsed",
      429,
      parsed,
      Some(1000),
      false,
      None,
      1000L,
      Some({ remaining: 0, reset_at_unix_ms: 2000L, }),
      None,
    ),
    (
      "429 without any delay",
      429,
      parsed,
      None,
      false,
      Some(1500L),
      1000L,
      parsed,
      Some(1500L),
    ),
    (
      "429 negative delay is zero",
      429,
      None,
      Some(-5),
      false,
      None,
      1000L,
      Some({ remaining: 0, reset_at_unix_ms: 1000L, }),
      None,
    ),
    (
      "global 429 keeps parsed",
      429,
      parsed,
      Some(1000),
      true,
      None,
      1000L,
      parsed,
      Some(2000L),
    ),
    (
      "global 429 extends a block",
      429,
      parsed,
      Some(1000),
      true,
      Some(1500L),
      1000L,
      parsed,
      Some(2000L),
    ),
    (
      "global 429 never shortens a block",
      429,
      None,
      Some(1000),
      true,
      Some(6000L),
      1000L,
      None,
      Some(6000L),
    ),
    (
      "429 delay saturates",
      429,
      None,
      Some(1000),
      false,
      None,
      max_ms - 10L,
      Some({ remaining: 0, reset_at_unix_ms: max_ms, }),
      None,
    ),
    (
      "global 429 delay saturates",
      429,
      None,
      Some(1000),
      true,
      None,
      max_ms - 10L,
      None,
      Some(max_ms),
    ),
  ]
  for row in rows {
    let (
      label,
      status,
      parsed,
      delay_ms,
      global,
      blocked_until,
      now,
      record,
      blocked,
    ) = row
    let effect = release_effect(
      status,
      parsed~,
      delay_ms~,
      global~,
      blocked_until~,
      now~,
    )
    assert_eq(effect.record, record, msg="\{label}: record")
    assert_eq(effect.blocked_until, blocked, msg="\{label}: block")
  }
}
