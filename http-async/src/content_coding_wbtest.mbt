///|
/// A plan as text: the codings undone, then what `Content-Encoding` keeps.
fn plan_label(values : Array[String]) -> String {
  try coding_plan(values) catch {
    @http.HttpError::Protocol(message) => message
    error => "unexpected \{Repr(error)}"
  } noraise {
    plan => {
      let undo = plan.undo.map(Coding::name).join(" ")
      let keep = plan.remaining.unwrap_or("-")
      "undo [\{undo}] keep \{keep}"
    }
  }
}

///|
test "coding_plan undoes known codings from the last applied" {
  let rows : Array[(String, Array[String], String)] = [
    ("no header", [], "undo [] keep -"),
    ("gzip", ["gzip"], "undo [gzip] keep -"),
    ("x-gzip is gzip", ["x-gzip"], "undo [gzip] keep -"),
    ("deflate", ["deflate"], "undo [deflate] keep -"),
    ("br", ["br"], "undo [br] keep -"),
    ("tokens are case-insensitive", ["GZip"], "undo [gzip] keep -"),
    ("br is case-insensitive too", ["BR"], "undo [br] keep -"),
    (
      "chained, last applied first",
      ["deflate, gzip"],
      "undo [gzip deflate] keep -",
    ),
    (
      "br chained with the others",
      ["br, deflate, gzip, br"],
      "undo [br gzip deflate br] keep -",
    ),
    (
      "repeated field lines join as one list",
      ["deflate", "gzip"],
      "undo [gzip deflate] keep -",
    ),
    (
      "identity and empty elements are ignored",
      [" identity , ,\tgzip ,"],
      "undo [gzip] keep -",
    ),
    ("only identity", ["identity"], "undo [] keep -"),
    ("unknown coding stays", ["zstd"], "undo [] keep zstd"),
    (
      "an unknown last coding hides the ones under it",
      ["gzip, br, zstd"],
      "undo [] keep gzip, br, zstd",
    ),
    (
      "an unknown first coding stays with its spelling",
      ["X-Custom ,deflate, gzip"],
      "undo [gzip deflate] keep X-Custom",
    ),
    (
      "codings before an unknown one stay",
      ["gzip, zstd, gzip"],
      "undo [gzip] keep gzip, zstd",
    ),
    (
      "five codings are allowed",
      ["gzip, gzip, gzip, gzip, gzip"],
      "undo [gzip gzip gzip gzip gzip] keep -",
    ),
    (
      "five br codings are allowed",
      ["br, br, br, br, br"],
      "undo [br br br br br] keep -",
    ),
    (
      "six codings are refused",
      ["gzip, gzip, gzip", "gzip, gzip, gzip"],
      "response has 6 content codings, more than 5",
    ),
    (
      "six codings are refused even if unknown",
      ["a, b, c, d, e, f"],
      "response has 6 content codings, more than 5",
    ),
    (
      "identity does not count toward the cap",
      ["identity, gzip, gzip, gzip, gzip, gzip, identity"],
      "undo [gzip gzip gzip gzip gzip] keep -",
    ),
  ]
  for row in rows {
    let (label, values, expected) = row
    assert_eq(plan_label(values), expected, msg=label)
  }
}

///|
test "decode_head rewrites only a head it decodes" {
  let rows : Array[(String, Array[(String, String)], String)] = [
    (
      "a decoded body loses its length and coding",
      [
        ("content-type", "text/plain"),
        ("content-encoding", "gzip"),
        ("content-length", "29"),
      ],
      "decoder content-type: text/plain",
    ),
    (
      "a partly decoded body keeps the codings left",
      [("content-encoding", "zstd, br"), ("content-length", "29")],
      "decoder content-encoding: zstd",
    ),
    (
      "an unknown coding leaves the head as it came",
      [("content-encoding", "zstd"), ("content-length", "29")],
      "none content-encoding: zstd; content-length: 29",
    ),
    (
      "a plain body leaves the head as it came",
      [("content-length", "2")],
      "none content-length: 2",
    ),
    (
      "too many codings raise",
      [("content-encoding", "gzip, gzip, gzip, gzip, gzip, gzip")],
      "response has 6 content codings, more than 5",
    ),
  ]
  for row in rows {
    let (label, pairs, expected) = row
    let head : @http.ResponseHead = {
      status: 200,
      headers: @http.Headers::from_array(pairs),
    }
    let outcome = try decode_head(head) catch {
      @http.HttpError::Protocol(message) => message
      error => "unexpected \{Repr(error)}"
    } noraise {
      decoder => {
        let kind = if decoder is Some(_) { "decoder" } else { "none" }
        let headers = head.headers
          .iter()
          .map(pair => pair.0 + ": " + pair.1)
          .collect()
          .join("; ")
        "\{kind} \{headers}"
      }
    }
    assert_eq(outcome, expected, msg=label)
  }
}

///|
test "Accept-Encoding offers exactly the codings the decoder undoes" {
  assert_eq(accept_encoding(), "gzip, deflate, br")
  for coding in decodable_codings {
    let plan = coding_plan([coding.name()]) catch { _ => panic() }
    assert_eq(plan.undo.length(), 1, msg=coding.name())
    assert_true(plan.remaining is None, msg=coding.name())
  }
}

///|
test "only responses that can carry a body are decoded" {
  let cases : Array[(String, Int32, Bool)] = [
    ("GET", 200, true),
    ("get", 206, true),
    ("POST", 500, true),
    ("HEAD", 200, false),
    ("head", 404, false),
    ("GET", 100, false),
    ("GET", 199, false),
    ("GET", 204, false),
    ("GET", 304, false),
    ("GET", 205, true),
  ]
  for case in cases {
    let (http_method, status, expected) = case
    assert_eq(
      has_body(http_method, status),
      expected,
      msg="\{http_method} \{status}",
    )
  }
}
