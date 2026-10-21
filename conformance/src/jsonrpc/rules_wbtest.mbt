///|
/// Lines around the framer's edges: CRLF, blank and whitespace-only lines,
/// multibyte text, and an unterminated tail.
let corpus : Array[Bytes] = [
  @utf8.encode("one\r\n\r\n two \n日本語🌙\r\nlast"),
  b"\n \n\t\n\r\nvalue\n",
  @utf8.encode("α\nβ\nγ"),
]

///|
test "the corpus holds to the rules" {
  let rand = @harness.seeded(20)
  for i, input in corpus {
    ignore(@harness.check_rules(() => line_feeder(), input, rand, label="\{i}"))
  }
}

///|
test "random streams hold to the rules under a line limit" {
  // Short lines, blank lines, lines over the limit and stray carriage
  // returns, with LF or CRLF terminators and maybe a tail.
  let rand = @harness.seeded(21)
  for case in 0..<300 {
    let max_line = 1 + rand.int(limit=6)
    let input = random_stream(rand, max_line)
    ignore(
      @harness.check_rules(
        () => line_feeder(max_line~),
        input,
        rand,
        label="case \{case} max_line=\{max_line}",
      ),
    )
  }
}

///|
test "corrupted streams hold to the rules" {
  let rand = @harness.seeded(22)
  let inputs = corpus.copy()
  for _ in 0..<8 {
    inputs.push(random_stream(rand, 4))
  }
  debug_inspect(
    @harness.fuzz(() => line_feeder(max_line=8), inputs, rand, rounds=300),
    content=(
      #|[("ok", 270), ("LineTooLong", 30)]
    ),
  )
}
