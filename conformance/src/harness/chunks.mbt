///|
/// A generator seeded with `seed` repeated to the 32 bytes ChaCha8 takes, so
/// that a failure can be replayed from the seed in its message.
pub fn seeded(seed : Int32) -> @random.Rand {
  @random.Rand::chacha8(seed=Bytes::make(32, seed.to_byte()))
}

///|
/// One chunk per byte.
pub fn single_bytes(input : Bytes) -> Array[Bytes] {
  input.iter().map(byte => Bytes::from_array([byte])).collect()
}

///|
/// Cuts after every CR and every non-ASCII byte, so each CRLF and each
/// multibyte UTF-8 character straddles a chunk boundary.
pub fn hostile_chunks(input : Bytes) -> Array[Bytes] {
  let chunks = []
  let mut start = 0
  for i, byte in input {
    if byte == b'\r' || byte >= b'\x80' {
      chunks.push(input[start:i + 1].to_owned())
      start = i + 1
    }
  }
  chunks.push(input[start:].to_owned())
  chunks
}

///|
/// Cuts `input` into chunks of 0 to 7 bytes, empty chunks included.
pub fn random_chunks(rand : @random.Rand, input : Bytes) -> Array[Bytes] {
  let chunks = []
  let mut start = 0
  while start < input.length() {
    let end = (start + rand.int(limit=8)).min(input.length())
    chunks.push(input[start:end].to_owned())
    start = end
  }
  chunks
}

///|
/// `input` changed in one to three places: a byte replaced, inserted or
/// removed, a run repeated, or the end cut off.
pub fn corrupt(rand : @random.Rand, input : Bytes) -> Bytes {
  let bytes = input.to_array()
  for _ in 0..<(1 + rand.int(limit=3)) {
    let at = rand.int(limit=bytes.length() + 1)
    match rand.int(limit=5) {
      0 if at < bytes.length() => bytes[at] = rand.int(limit=256).to_byte()
      1 => bytes.insert(at, rand.int(limit=256).to_byte())
      2 if at < bytes.length() => bytes.remove(at) |> ignore
      3 if at < bytes.length() => {
        let end = (at + 1 + rand.int(limit=8)).min(bytes.length())
        let run = bytes[at:end].to_owned()
        for i, byte in run {
          bytes.insert(end + i, byte)
        }
      }
      _ => bytes.truncate(at)
    }
  }
  Bytes::from_array(bytes)
}
