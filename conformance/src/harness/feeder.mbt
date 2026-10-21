///|
/// A failure an adapter reports, by its kind: two runs agree when they fail
/// with the same kind, whatever the message.
pub(all) suberror Failed {
  Failed(String)
} derive(Debug)

///|
/// An incremental parser as the checks see it: chunks in, results out, each
/// result rendered as a string the checks can compare. `finish` says the
/// input has ended.
pub(open) trait Feeder {
  fn feed(Self, Bytes) -> Array[String] raise Failed
  fn finish(Self) -> Array[String] raise Failed
}

///|
/// What a run produced: every result in order, and the kind of the error
/// that ended it, if one did.
pub(all) struct Transcript {
  results : Array[String]
  error : String?
} derive(Eq, Debug)

///|
/// Compares results and error kinds.
pub extend Transcript with Eq::{equal, not_equal}

///|
/// Formats a transcript for test failures.
pub extend Transcript with @debug.Debug::{to_repr}

///|
/// Feeds `chunks` in order, then finishes, stopping at the first error.
pub fn[F : Feeder] run(parser : F, chunks : Array[Bytes]) -> Transcript {
  let results = []
  try {
    for chunk in chunks {
      results.append(parser.feed(chunk))
    }
    results.append(parser.finish())
    { results, error: None, }
  } catch {
    Failed(kind) => { results, error: Some(kind), }
  }
}

///|
/// Formats a failure for test messages.
pub extend Failed with @debug.Debug::{to_repr}
