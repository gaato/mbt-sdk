///|
/// The largest slice one `ContentDecoder::pull` returns, so a decoded read is
/// no larger than a plain one (`max_read_bytes`) however well the body packs.
let decoded_slice_bytes : Int32 = 64 * 1024

///|
/// The largest `br` window accepted, as a power of two: RFC 7932's largest,
/// 16 MiB, as browsers accept, since a smaller cap refuses valid streams.
/// The decoder grows the window only as output needs it, so a stream that
/// declares 16 MiB and decodes to little holds little.
let brotli_window_bits : Int32 = 24

///|
/// The largest `zstd` window accepted, as a power of two: 8 MiB, which RFC
/// 9659 requires HTTP recipients to accept and encoders not to exceed for
/// the `zstd` coding. As for `br`, the window grows only as output needs it.
let zstd_window_bits : Int32 = 23

///|
/// One coding being undone. Its input is the previous stage's output, or the
/// wire for the first stage.
priv struct Stage {
  coding : Coding
  /// `None` for a `deflate` body until its first two bytes, which tell zlib
  /// from raw DEFLATE, have arrived.
  mut decoder : &@codec_bytes.Decode?
  /// The at most one byte of a `deflate` body seen before that.
  mut sniffed : Bytes
  /// Input accepted from upstream and not yet consumed.
  mut input : BytesView
  /// Upstream has nothing more.
  mut input_ended : Bool
  /// Some input has arrived.
  mut started : Bool
  /// The coded stream reached its end, and nothing followed it.
  mut finished : Bool
  /// The last step stopped for output room: the decoder may have taken all
  /// the input and still hold decoded bytes, so step again before asking
  /// upstream for more.
  mut output_pending : Bool
  /// The error of a step that wrote output before it raised. That output
  /// goes out as a slice and the error on the next pull, so what a stream's
  /// reader gets before the error does not depend on how the wire is chunked.
  mut failure : @http.HttpError?
  output : FixedArray[Byte]
}

///|
/// Undoes a chain of content codings incrementally. The caller pulls decoded
/// slices; when `pull` answers `NeedInput` it feeds the next wire chunk, or
/// ends the input. Memory is bounded whatever the body: per stage, a
/// `decoded_slice_bytes` output buffer and the decoder's state, which for
/// gzip and `deflate` is gaato/deflate's 32 KiB window and tables (74,240
/// bytes; a gzip header's extra field, name and comment are skipped, not
/// held), for `br` a window of at most `1 << brotli_window_bits` bytes, never
/// more than the stage's output so far, and at most 1.3 MiB of tables, and
/// for `zstd` a window of at most `1 << zstd_window_bits` bytes, likewise no
/// more than the output so far, one block of at most 128 KiB and its
/// literals, and about 11 KiB of tables. Each slice is a fresh `Bytes` of at
/// most `decoded_slice_bytes`.
priv struct ContentDecoder {
  /// The first stage reads the wire; each later one reads the stage before.
  stages : Array[Stage]
}

///|
/// What one `pull` produced.
priv enum Pulled {
  /// A decoded slice, never empty.
  Slice(Bytes)
  /// Feed a wire chunk, or end the input, then pull again.
  NeedInput
  /// The body is decoded in full, and nothing followed it.
  Done
}

///|
/// A decoder that undoes `undo`, last applied coding first.
fn ContentDecoder::new(undo : Array[Coding]) -> ContentDecoder {
  let stages = undo.map(coding => {
    coding,
    decoder: match coding {
      Gzip => Some(@gzip.Decoder(keep_header=false))
      Deflate => None
      Brotli => Some(@brotli.Decoder(max_window_bits=brotli_window_bits))
      Zstd => Some(@zstd.Decoder(max_window_bits=zstd_window_bits))
    },
    sniffed: b"",
    input: b""[:],
    input_ended: false,
    started: false,
    finished: false,
    output_pending: false,
    failure: None,
    output: FixedArray::make(decoded_slice_bytes, b'\x00'),
  })
  { stages, }
}

///|
/// Hands the decoder the next wire chunk, after `pull` answered `NeedInput`.
fn ContentDecoder::feed(self : ContentDecoder, chunk : Bytes) -> Unit {
  self.stages[0].input = chunk[:]
}

///|
/// Tells the decoder the wire has nothing more, after `pull` answered
/// `NeedInput`.
fn ContentDecoder::end(self : ContentDecoder) -> Unit {
  self.stages[0].input_ended = true
}

///|
/// The next decoded slice, or what the decoder needs before it can tell.
/// Corrupt, truncated or trailing coded data raises `Protocol`, after the
/// slices decoded before it.
fn ContentDecoder::pull(self : ContentDecoder) -> Pulled raise @http.HttpError {
  self.pull_stage(self.stages.length() - 1)
}

///|
/// Each stage's decoder keeps gaato/codec_bytes' rules: a step that answers
/// `NeedMoreInput` took all its input and wrote everything that input
/// determines, `NeedMoreOutput` means the slice is full, and `Done` comes
/// only with the input ended and nothing after the stream, whose bytes the
/// decoder refuses itself. So the loop cannot spin.
fn ContentDecoder::pull_stage(
  self : ContentDecoder,
  index : Int32,
) -> Pulled raise @http.HttpError {
  let stage = self.stages[index]
  if stage.failure is Some(error) {
    raise error
  }
  for ;; {
    if stage.finished {
      return Done
    }
    if stage.input.length() == 0 && !stage.input_ended && !stage.output_pending {
      if index == 0 {
        return NeedInput
      }
      match self.pull_stage(index - 1) {
        Slice(slice) => stage.input = slice[:]
        NeedInput => return NeedInput
        Done => stage.input_ended = true
      }
    }
    if !stage.started {
      if stage.input.length() == 0 {
        // An empty body, as for HEAD, 204 or 304, is empty in any coding.
        stage.finished = true
        continue
      }
      stage.started = true
    }
    let decoder = match stage.decoder {
      Some(decoder) => decoder
      None => {
        let joined = stage.sniffed + stage.input.to_owned()
        if joined.length() < 2 && !stage.input_ended {
          stage.sniffed = joined
          stage.input = b""[:]
          continue
        }
        let decoder = if joined.length() >= 2 &&
          @zlib.is_header(joined[0], joined[1]) {
          (@zlib.Decoder() : &@codec_bytes.Decode)
        } else {
          // Raw DEFLATE, which also refuses a body of one byte as cut short.
          @deflate.Decoder()
        }
        stage.decoder = Some(decoder)
        stage.input = joined[:]
        decoder
      }
    }
    let status = decoder.step(
      stage.input,
      stage.output.mut_view(),
      end=stage.input_ended,
    ) catch {
      CodecError(_, message) => {
        let error = malformed(stage.coding, message)
        let produced = decoder.last_produced()
        guard produced > 0 else { raise error }
        stage.failure = Some(error)
        return Slice(Bytes::from_array(stage.output[:produced]))
      }
    }
    stage.input = stage.input[decoder.last_consumed():]
    stage.output_pending = status is NeedMoreOutput
    stage.finished = status is Done
    let produced = decoder.last_produced()
    if produced > 0 {
      return Slice(Bytes::from_array(stage.output[:produced]))
    }
  }
}

///|
fn malformed(coding : Coding, message : String) -> @http.HttpError {
  @http.HttpError::Protocol(
    "malformed \{coding.name()} response body: \{message}",
  )
}
