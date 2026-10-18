///|
/// Feeds `chunks` to `read_bounded` and labels the outcome with the number of
/// chunks it read.
async fn bounded_label(chunks : Array[Bytes], max_bytes : Int32) -> String {
  let mut reads = 0
  let read : async () -> Bytes? = () => {
    reads += 1
    chunks.get(reads - 1)
  }
  let outcome = try read_bounded(read, max_bytes) catch {
    @http.HttpError::Protocol(message) => message
    error => "unexpected \{Repr(error)}"
  } noraise {
    body => "\{body.length()} bytes"
  }
  "\{outcome} after \{reads} reads"
}

///|
async test "read_bounded stops at the chunk that crosses the limit" {
  let rows : Array[(Array[Bytes], Int32, String)] = [
    ([], 0, "0 bytes after 1 reads"),
    ([b"ab"], 2, "2 bytes after 2 reads"),
    ([b"a", b"", b"b"], 2, "2 bytes after 4 reads"),
    ([b"ab", b"c"], 2, "response body larger than 2 bytes after 2 reads"),
    ([b"abc", b"d"], 2, "response body larger than 2 bytes after 1 reads"),
    ([b"a"], 0, "response body larger than 0 bytes after 1 reads"),
  ]
  for row in rows {
    let (chunks, max_bytes, expected) = row
    assert_eq(bounded_label(chunks, max_bytes), expected)
  }
}
