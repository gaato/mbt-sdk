///|
/// A pool of integer connections, each parked as
/// `(origin, id, user_agent, parked_at_ms)`, in parking order.
fn pool_of(
  parked : Array[(String, Int32, String?, Int64)],
  max_per_origin~ : Int32 = 4,
  idle_max_ms~ : Int32 = 100,
) -> IdlePool[Int32] {
  let pool = IdlePool::new(max_per_origin~, idle_max_ms~)
  for entry in parked {
    let (origin, conn, user_agent, parked_at_ms) = entry
    pool.parked
    .get_or_init(origin, () => [])
    .push({ conn, user_agent, parked_at_ms, })
  }
  pool
}

///|
/// The parked ids per origin, oldest first, e.g. `a[1 2] b[3]`.
fn parked_ids(pool : IdlePool[Int32]) -> String {
  let origins = []
  for origin, parked in pool.parked {
    let ids = parked.map(idle => idle.conn.to_string())
    origins.push(origin + "[" + ids.join(" ") + "]")
  }
  origins.join(" ")
}

///|
fn sorted(conns : Array[Int32]) -> Array[Int32] {
  let copy = conns.copy()
  copy.sort()
  copy
}

///|
test "take reuses the newest young connection with the same User-Agent" {
  // now = 1000 and idle_max_ms = 100, so a connection parked at 900 is expired.
  let rows : Array[
    (
      String,
      Array[(String, Int32, String?, Int64)],
      String?,
      Int32?,
      Array[Int32],
      String,
    ),
  ] = [
    ("empty pool", [], None, None, [], ""),
    (
      "age exactly idle_max is expired",
      [("a", 1, None, 900)],
      None,
      None,
      [1],
      "",
    ),
    ("age idle_max - 1 is reused", [("a", 1, None, 901)], None, Some(1), [], ""),
    (
      "User-Agent mismatch is skipped",
      [("a", 1, Some("x"), 950)],
      Some("y"),
      None,
      [],
      "a[1]",
    ),
    (
      "no User-Agent does not match one",
      [("a", 1, Some("x"), 950)],
      None,
      None,
      [],
      "a[1]",
    ),
    (
      "a User-Agent does not match none",
      [("a", 1, None, 950)],
      Some("x"),
      None,
      [],
      "a[1]",
    ),
    (
      "newest wins",
      [("a", 1, None, 950), ("a", 2, None, 960)],
      None,
      Some(2),
      [],
      "a[1]",
    ),
    (
      "expired entries older than the match are closed too",
      [("a", 1, None, 800), ("a", 2, None, 950)],
      None,
      Some(2),
      [1],
      "",
    ),
    (
      "expired entries before a mismatch are closed",
      [("a", 1, Some("x"), 950), ("a", 2, None, 850)],
      None,
      None,
      [2],
      "a[1]",
    ),
    (
      "expired entries of other origins are closed",
      [("b", 1, None, 800), ("a", 2, None, 950)],
      None,
      Some(2),
      [1],
      "",
    ),
    (
      "young entries of other origins stay",
      [("b", 1, None, 950), ("a", 2, None, 950)],
      None,
      Some(2),
      [],
      "b[1]",
    ),
    ("unknown origin", [("b", 1, None, 950)], None, None, [], "b[1]"),
  ]
  for row in rows {
    let (label, parked, user_agent, reused, closed, remaining) = row
    let pool = pool_of(parked)
    let (got, expired) = pool.take("a", user_agent, now=1000)
    assert_eq(got, reused, msg=label)
    assert_eq(sorted(expired), closed, msg=label)
    assert_eq(parked_ids(pool), remaining, msg=label)
  }
}

///|
test "put parks below the cap and hands back what it cannot keep" {
  // The connection being checked in is 99; now = 1000.
  let rows : Array[
    (
      String,
      Int32,
      Int32,
      Bool,
      Array[(String, Int32, String?, Int64)],
      Array[Int32],
      String,
    ),
  ] = [
    ("first park creates the origin", 1, 100, false, [], [], "a[99]"),
    ("below the cap parks", 2, 100, false, [("a", 1, None, 950)], [], "a[1 99]"),
    (
      "live == max closes the new one",
      1,
      100,
      false,
      [("a", 1, None, 950)],
      [99],
      "a[1]",
    ),
    (
      "another origin's count does not apply",
      1,
      100,
      false,
      [("b", 1, None, 950)],
      [],
      "b[1] a[99]",
    ),
    ("max_idle = 0 disables reuse", 0, 100, false, [], [99], ""),
    ("idle_max = 0 disables reuse", 4, 0, false, [], [99], ""),
    ("closed pool parks nothing", 4, 100, true, [], [99], ""),
    (
      "expired entries do not count toward the cap",
      1,
      100,
      false,
      [("a", 1, None, 800)],
      [1],
      "a[99]",
    ),
    (
      "expired entries of other origins are closed",
      4,
      100,
      false,
      [("b", 1, None, 800)],
      [1],
      "a[99]",
    ),
  ]
  for row in rows {
    let (
      label,
      max_per_origin,
      idle_max_ms,
      closed,
      parked,
      handed_back,
      remaining,
    ) = row
    let pool = pool_of(parked, max_per_origin~, idle_max_ms~)
    pool.closed = closed
    let rejected = pool.put("a", None, 99, now=1000)
    assert_eq(sorted(rejected), handed_back, msg=label)
    assert_eq(parked_ids(pool), remaining, msg=label)
  }
}

///|
test "drain hands back every parked connection and closes the pool" {
  let pool = pool_of([
    ("a", 1, None, 950),
    ("b", 2, None, 950),
    ("a", 3, None, 960),
  ])
  assert_eq(pool.count(), 3)
  assert_eq(sorted(pool.drain()), [1, 2, 3])
  assert_eq(pool.count(), 0)
  assert_eq(pool.put("a", None, 4, now=1000), [4])
}

///|
test "replayable allows idempotent methods or an idempotency key" {
  let rows : Array[(String, Array[(String, String)], Bool)] = [
    ("GET", [], true),
    ("get", [], true),
    ("HEAD", [], true),
    ("PUT", [], true),
    ("Delete", [], true),
    ("OPTIONS", [], true),
    ("TRACE", [], true),
    ("POST", [], false),
    ("PATCH", [], false),
    ("CONNECT", [], false),
    ("PURGE", [], false),
    ("POST", [("Idempotency-Key", "k")], true),
    ("PATCH", [("idempotency-key", "")], true),
    ("POST", [("x-idempotency-key", "k")], false),
  ]
  for row in rows {
    let (http_method, headers, expected) = row
    let request : @http.Request = {
      http_method,
      url: "http://example.com/",
      headers: @http.Headers::from_array(headers),
      body: b"",
    }
    assert_eq(
      replayable(request),
      expected,
      msg="\{http_method} [\{pairs_label(headers.iter())}]",
    )
  }
}

///|
test "connection_close looks for the close token" {
  let rows : Array[(Array[(String, String)], Bool)] = [
    ([], false),
    ([("Connection", "keep-alive")], false),
    ([("Connection", "close")], true),
    ([("connection", "Close")], true),
    ([("CONNECTION", "CLOSE")], true),
    ([("Connection", " close ")], true),
    ([("Connection", "keep-alive, close")], true),
    ([("Connection", "close,upgrade")], true),
    ([("Connection", "Upgrade")], false),
    ([("Connection", "closed-ish")], false),
    ([("Connection", "keep-alive, x-close")], false),
    ([("Connection", "")], false),
    ([("X-Connection", "close")], false),
    ([("X-Status", "close")], false),
  ]
  for row in rows {
    let (headers, expected) = row
    let response : @ahttp.Response = {
      code: 200,
      reason: "OK",
      headers: Map(
        headers.map(pair => (@ahttp.CaseInsensitiveString(pair.0), pair.1)),
      ),
      cookies: [],
    }
    assert_eq(
      connection_close(response),
      expected,
      msg=pairs_label(headers.iter()),
    )
  }
}
