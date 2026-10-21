///|
/// Inputs up to this long are cut, and truncated, at every place; longer
/// ones at both ends and this many random places, so that a check costs
/// about as much as a few hundred runs whatever the input. The splits a
/// parser gets wrong are near terminators and characters, which the
/// byte-at-a-time and hostile runs reach on every input.
let max_places : Int32 = 64

///|
/// The places in an input of `length` bytes to cut or truncate at.
fn places(length : Int32, rand : @random.Rand) -> Array[Int32] {
  if length <= max_places {
    Array::makei(length + 1, i => i)
  } else {
    [0, length, ..Array::makei(max_places, _ => rand.int(limit=length + 1))]
  }
}

///|
/// Rule: the results and the error kind do not depend on how the input is
/// cut. Runs `input` whole, cut in two (at every place, for a short input),
/// one byte at a time, cut around every CR and non-ASCII byte, and cut at
/// random, and requires every run to agree with the whole one, which it
/// returns.
pub fn[F : Feeder] check_splits(
  make : () -> F,
  input : Bytes,
  rand : @random.Rand,
  label~ : String = "",
) -> Transcript raise {
  let whole = run(make(), [input])
  for cut in places(input.length(), rand) {
    let chunks = [input[:cut].to_owned(), input[cut:].to_owned()]
    assert_eq(run(make(), chunks), whole, msg="\{label} cut at \{cut}")
  }
  assert_eq(run(make(), single_bytes(input)), whole, msg="\{label} bytes")
  assert_eq(run(make(), hostile_chunks(input)), whole, msg="\{label} hostile")
  for round in 0..<4 {
    assert_eq(
      run(make(), random_chunks(rand, input)),
      whole,
      msg="\{label} random \{round}",
    )
  }
  whole
}

///|
/// Rule: a parser gives out only what its input determines. For a prefix
/// of `input` (every prefix, for a short input), what `feed` returns is a
/// prefix of the whole run's results, and `feed` fails only with the kind
/// the whole run fails with.
/// `finish` is not checked: a prefix is a stream of its own, whose end may
/// mean something else, as a line cut before its terminator does.
pub fn[F : Feeder] check_truncation(
  make : () -> F,
  input : Bytes,
  rand : @random.Rand,
  label~ : String = "",
) -> Unit raise {
  let whole = run(make(), [input])
  for end in places(input.length(), rand) {
    let parser = make()
    let fed = parser.feed(input[:end].to_owned()) catch {
      Failed(kind) => {
        assert_eq(Some(kind), whole.error, msg="\{label} feed of \{end} bytes")
        continue
      }
    }
    assert_true(
      fed.length() <= whole.results.length() &&
      fed == whole.results[:fed.length()].to_owned(),
      msg="\{label} feed of \{end} bytes gave \{Repr(fed)}, not a prefix of \{Repr(whole.results)}",
    )
  }
}

///|
/// Rule: once a parser has finished, or raised, it is done. Every later
/// `feed` and `finish` returns nothing and raises nothing.
pub fn[F : Feeder] check_after_end(
  make : () -> F,
  input : Bytes,
  label~ : String = "",
) -> Unit raise {
  let parser = make()
  try {
    ignore(parser.feed(input))
    ignore(parser.finish())
  } catch {
    Failed(_) => ()
  }
  for round in 0..<2 {
    assert_eq(parser.feed(input), [], msg="\{label} feed after end \{round}")
    assert_eq(parser.finish(), [], msg="\{label} finish after end \{round}")
  }
}

///|
/// All three rules on one input.
pub fn[F : Feeder] check_rules(
  make : () -> F,
  input : Bytes,
  rand : @random.Rand,
  label~ : String = "",
) -> Transcript raise {
  let whole = check_splits(make, input, rand, label~)
  check_truncation(make, input, rand, label~)
  check_after_end(make, input, label~)
  whole
}

///|
/// Corrupts inputs drawn from `inputs` `rounds` times and holds every
/// corrupted input to the rules. Returns how often each outcome happened,
/// `"ok"` or an error kind, sorted by outcome, for a snapshot to pin.
pub fn[F : Feeder] fuzz(
  make : () -> F,
  inputs : Array[Bytes],
  rand : @random.Rand,
  rounds~ : Int32,
) -> Array[(String, Int32)] raise {
  let counts : Map[String, Int32] = Map([])
  for round in 0..<rounds {
    let input = corrupt(rand, inputs[rand.int(limit=inputs.length())])
    let whole = check_rules(make, input, rand, label="fuzz round \{round}")
    let outcome = whole.error.unwrap_or("ok")
    counts[outcome] = counts.get(outcome).unwrap_or(0) + 1
  }
  counts.to_array()..sort_by((a, b) => a.0.compare(b.0))
}
