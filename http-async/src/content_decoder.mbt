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
/// The decompressor of one stage.
priv enum Decompressor {
  Gzip(@gzip.Decoder)
  Zlib(@zlib.Decoder)
  Raw(@flate.Inflater)
  Brotli(@brotli.Decoder)
  Zstd(@zstd.Decoder)
}

///|
/// One coding being undone. Its input is the previous stage's output, or the
/// wire for the first stage.
priv struct Stage {
  coding : Coding
  /// `None` for a `deflate` body until its first two bytes, which tell zlib
  /// from raw DEFLATE, have arrived.
  mut decompressor : Decompressor?
  /// The at most one byte of a `deflate` body seen before that.
  mut sniffed : Bytes
  /// Input accepted from upstream and not yet consumed.
  mut input : BytesView
  /// Upstream has nothing more.
  mut input_ended : Bool
  /// Some input has arrived.
  mut started : Bool
  /// The coded stream reached its end.
  mut finished : Bool
  /// The last step stopped for output room: gzip, zlib, Brotli and zstd may have
  /// taken all the input and still hold decoded bytes, so step again before
  /// asking upstream for more.
  mut output_pending : Bool
  output : FixedArray[Byte]
}

///|
/// Undoes a chain of content codings incrementally. The caller pulls decoded
/// slices; when `pull` answers `NeedInput` it feeds the next wire chunk, or
/// ends the input. Memory is bounded whatever the body: per stage, a
/// `decoded_slice_bytes` output buffer and the decompressor's state, which
/// for gzip and `deflate` is a 32 KiB window and flate's bounded pending
/// input, for `br` a window of at most `1 << brotli_window_bits` bytes,
/// never more than the stage's output so far, and at most 1.3 MiB of tables,
/// and for `zstd` a window of at most `1 << zstd_window_bits` bytes, likewise
/// no more than the output so far, one block of at most 128 KiB and its
/// literals, and about 11 KiB of tables.
/// Each slice is a fresh `Bytes` of at most `decoded_slice_bytes`.
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
    decompressor: match coding {
      Gzip => Some(Gzip(@gzip.Decoder()))
      Deflate => None
      Brotli =>
        Some(Brotli(@brotli.Decoder(max_window_bits=brotli_window_bits)))
      Zstd => Some(Zstd(@zstd.Decoder(max_window_bits=zstd_window_bits)))
    },
    sniffed: b"",
    input: b""[:],
    input_ended: false,
    started: false,
    finished: false,
    output_pending: false,
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
/// Corrupt, truncated or trailing coded data raises `Protocol`.
fn ContentDecoder::pull(self : ContentDecoder) -> Pulled raise @http.HttpError {
  self.pull_stage(self.stages.length() - 1)
}

///|
fn ContentDecoder::pull_stage(
  self : ContentDecoder,
  index : Int32,
) -> Pulled raise @http.HttpError {
  let stage = self.stages[index]
  for ;; {
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
    if stage.finished {
      // Read the rest of the input to be sure nothing follows the stream.
      guard stage.input.length() == 0 else {
        raise malformed(stage.coding, "data after the end of the stream")
      }
      if stage.input_ended {
        return Done
      }
      continue
    }
    if !stage.started {
      if stage.input.length() == 0 {
        // An empty body, as for HEAD, 204 or 304, is empty in any coding.
        stage.finished = true
        continue
      }
      stage.started = true
    }
    let decompressor = match stage.decompressor {
      Some(decompressor) => decompressor
      None => {
        let joined = stage.sniffed + stage.input.to_owned()
        if joined.length() < 2 {
          guard !stage.input_ended else {
            raise malformed(stage.coding, "the stream ends after one byte")
          }
          stage.sniffed = joined
          stage.input = b""[:]
          continue
        }
        let decompressor = if zlib_header(joined[0], joined[1]) {
          Zlib(@zlib.Decoder())
        } else {
          Raw(@flate.Inflater())
        }
        stage.decompressor = Some(decompressor)
        stage.input = joined[:]
        decompressor
      }
    }
    let (status, consumed, produced) = decompressor.step(
      stage.input,
      stage.output,
      end=stage.input_ended,
      coding=stage.coding,
    )
    stage.input = stage.input[consumed:]
    stage.output_pending = status is @flate.NeedMoreOutput
    if status is @flate.Done {
      stage.finished = true
      // Bytes read ahead past the end, which gzip and zlib keep aside.
      // Brotli and zstd raise on them themselves.
      let unused = match decompressor {
        Gzip(decoder) => decoder.unused_input().length()
        Zlib(decoder) => decoder.unused_input().length()
        Raw(_) | Brotli(_) | Zstd(_) => 0
      }
      guard unused == 0 else {
        raise malformed(stage.coding, "data after the end of the stream")
      }
    }
    if produced > 0 {
      return Slice(Bytes::from_array(stage.output[:produced]))
    }
    // Without output, a step must have consumed input, finished, or be
    // waiting for input upstream can still give. flate, Brotli and zstd always
    // progress with free output; never spin if they did not.
    guard consumed > 0 ||
      status is @flate.Done ||
      (
        status is @flate.NeedMoreInput &&
        stage.input.length() == 0 &&
        !stage.input_ended
      ) else {
      raise malformed(stage.coding, "the decoder made no progress")
    }
  }
}

///|
/// One decompression step from `input` into `output`: the status and the
/// bytes consumed and produced. Brotli's and zstd's `Status` have the same three cases
/// as flate's, which the stages share.
fn Decompressor::step(
  self : Decompressor,
  input : BytesView,
  output : FixedArray[Byte],
  end~ : Bool,
  coding~ : Coding,
) -> (@flate.Status, Int32, Int32) raise @http.HttpError {
  match self {
    Gzip(decoder) => {
      let status = decoder.step_into(input, output, end~) catch {
        @gzip.GzipError(_, message) => raise malformed(coding, message)
      }
      (status, decoder.last_consumed(), decoder.last_produced())
    }
    Zlib(decoder) => {
      let status = decoder.step_into(input, output, end~) catch {
        @zlib.ZlibError(_, message) => raise malformed(coding, message)
      }
      (status, decoder.last_consumed(), decoder.last_produced())
    }
    Raw(inflater) => {
      let status = inflater.step_into(input, output, end~) catch {
        @flate.InflateError(_, message) => raise malformed(coding, message)
      }
      (status, inflater.last_consumed(), inflater.last_produced())
    }
    Brotli(decoder) => {
      let status = decoder.step_into(input, output, end~) catch {
        @brotli.BrotliError(_, message) => raise malformed(coding, message)
      }
      let status : @flate.Status = match status {
        Done => Done
        NeedMoreInput => NeedMoreInput
        NeedMoreOutput => NeedMoreOutput
      }
      (status, decoder.last_consumed(), decoder.last_produced())
    }
    Zstd(decoder) => {
      let status = decoder.step_into(input, output, end~) catch {
        @zstd.ZstdError(_, message) => raise malformed(coding, message)
      }
      let status : @flate.Status = match status {
        Done => Done
        NeedMoreInput => NeedMoreInput
        NeedMoreOutput => NeedMoreOutput
      }
      (status, decoder.last_consumed(), decoder.last_produced())
    }
  }
}

///|
/// Whether two bytes open a zlib stream (RFC 1950): the DEFLATE method, a
/// window of at most 32 KiB, and a header that is a multiple of 31. `deflate`
/// is zlib by RFC 9110, but servers have sent raw DEFLATE under the name,
/// so browsers check these bytes and httpx retries raw on a zlib error.
fn zlib_header(cmf : Byte, flg : Byte) -> Bool {
  let cmf = cmf.to_int()
  (cmf & 0x0F) == 8 && cmf >> 4 <= 7 && ((cmf << 8) | flg.to_int()) % 31 == 0
}

///|
fn malformed(coding : Coding, message : String) -> @http.HttpError {
  @http.HttpError::Protocol(
    "malformed \{coding.name()} response body: \{message}",
  )
}
