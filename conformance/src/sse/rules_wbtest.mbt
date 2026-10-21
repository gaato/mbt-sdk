///|
/// Streams around the parser's edges: CRLF and lone CR, a BOM, multibyte
/// text, empty and bare fields, comments, ids with NUL, retry hints, and
/// invalid UTF-8.
let corpus : Array[Bytes] = [
  @utf8.encode("data: a\r\ndata: b\r\n\r\ndata: c\r\n\r\n"),
  @utf8.encode("data: a\r\rdata: b\r\r"),
  @utf8.encode("\u{FEFF}data: 日本語🌙\n\n"),
  @utf8.encode("data: one\ndata:\ndata: three\n\ndata\n\n"),
  @utf8.encode(": comment\r\nunknown: ignored\rdata: x\n\n"),
  @utf8.encode("id: abc\nretry: 123\n\ndata: x\n\nid: a\u{0000}b\ndata: y\n\n"),
  @utf8.encode("\u{FEFF}\u{FEFF}data: no\ndata: yes\n\ndata: incomplete"),
  b"data: \xf0\x9f\x8c\x99\xff\xe3\x81\r\n\r\n",
]

///|
/// Raw bytes around the parser's edges: terminators, field punctuation,
/// fragments of multibyte characters and a BOM, and invalid UTF-8.
let raw_alphabet : Array[Byte] = [
  b'd', b'a', b't', b'i', b'r', b'e', b'y', b':', b' ', b'1', b'\r', b'\n', b'\n',
  b'\x00', b'\xe6', b'\x97', b'\xa5', b'\xef', b'\xbb', b'\xbf', b'\xff',
]

///|
test "the corpus holds to the rules" {
  let rand = @harness.seeded(0)
  for i, input in corpus {
    ignore(@harness.check_rules(() => sse_feeder(), input, rand, label="\{i}"))
  }
}

///|
test "generated streams parse to their events and hold to the rules" {
  for seed in 1..<5 {
    let rand = @harness.seeded(seed)
    for case in 0..<100 {
      let (input, expected) = generate_stream(rand)
      let label = "seed \{seed} case \{case}"
      let whole = @harness.check_rules(() => sse_feeder(), input, rand, label~)
      assert_eq(whole, { results: render(expected), error: None, }, msg=label)
    }
  }
}

///|
test "random bytes hold to the rules" {
  for seed in 5..<9 {
    let rand = @harness.seeded(seed)
    for case in 0..<100 {
      let input = Bytes::makei(rand.int(limit=64), _ => {
        raw_alphabet[rand.int(limit=raw_alphabet.length())]
      })
      ignore(
        @harness.check_rules(
          () => sse_feeder(),
          input,
          rand,
          label="seed \{seed} case \{case}",
        ),
      )
    }
  }
}

///|
test "a bounded parser refuses generated streams by the rules" {
  // Every event completed before an overflow is still delivered, so a
  // bounded run gives a prefix of the unbounded events, and all of them when
  // it is not refused.
  for seed in 9..<13 {
    let rand = @harness.seeded(seed)
    for case in 0..<100 {
      let (input, unbounded) = generate_stream(rand)
      let limit = rand.int(limit=40)
      let label = "seed \{seed} case \{case} limit \{limit}"
      let whole = @harness.check_rules(
        () => sse_feeder(max_event_bytes=limit),
        input,
        rand,
        label~,
      )
      let all = render(unbounded)
      assert_true(
        whole.results.length() <= all.length() &&
        whole.results == all[:whole.results.length()].to_owned(),
        msg="\{label} prefix",
      )
      assert_true(
        whole.error == Some("Protocol") || whole.results == all,
        msg="\{label} all",
      )
    }
  }
}

///|
test "corrupted streams hold to the rules" {
  let rand = @harness.seeded(13)
  let inputs = corpus.copy()
  for _ in 0..<8 {
    inputs.push(generate_stream(rand).0)
  }
  debug_inspect(
    @harness.fuzz(
      () => sse_feeder(max_event_bytes=24),
      inputs,
      rand,
      rounds=300,
    ),
    content=(
      #|[("ok", 215), ("Protocol", 85)]
    ),
  )
}
