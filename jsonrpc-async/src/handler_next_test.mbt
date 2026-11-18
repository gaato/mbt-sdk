///|
impl @io.BinaryWriterImpl for RecordedWriter with fn name(_) {
  "RecordedWriter"
}

///|
/// RecordedWriter keeps no bytes back: each write is recorded whole.
impl @io.BinaryWriterImpl for RecordedWriter with fn flush_partial_data(_) {

}
