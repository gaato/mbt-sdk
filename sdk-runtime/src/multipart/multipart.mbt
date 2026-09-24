///|
/// A single multipart/form-data field with an optional filename and media type.
pub(all) struct Part {
  name : String
  filename : String?
  content_type : String?
  body : Bytes
} derive(Eq, Debug)

///|
/// Compares every part field, including the body bytes.
pub extend Part with Eq::{equal, not_equal}

///|
/// Formats a part for debugging.
pub extend Part with @debug.Debug::{to_repr}

///|
/// Creates a UTF-8 text field without a content type.
///
/// ```mbt check
/// test {
///   assert_eq(@multipart.Part::text("message", "hello").body, b"hello")
/// }
/// ```
pub fn Part::text(name : String, value : String) -> Part {
  { name, filename: None, content_type: None, body: @utf8.encode(value), }
}

///|
/// Creates a file field, preserving the supplied body bytes exactly.
///
/// ```mbt check
/// test {
///   let part = @multipart.Part::file(
///     "upload", "data.bin", "application/octet-stream", b"\x00\xFF",
///   )
///   assert_eq(part.filename, Some("data.bin"))
///   assert_eq(part.body, b"\x00\xFF")
/// }
/// ```
pub fn Part::file(
  name : String,
  filename : String,
  content_type : String,
  body : Bytes,
) -> Part {
  { name, filename: Some(filename), content_type: Some(content_type), body, }
}

///|
/// Creates a JSON field encoded as UTF-8 with content type application/json.
///
/// ```mbt check
/// test {
///   let part = @multipart.Part::json("metadata", { "ok": true })
///   assert_eq(part.content_type, Some("application/json"))
///   assert_eq(part.body, b"{\"ok\":true}")
/// }
/// ```
pub fn Part::json(name : String, value : Json) -> Part {
  {
    name,
    filename: None,
    content_type: Some("application/json"),
    body: @utf8.encode(value.stringify()),
  }
}

///|
/// Multipart validation and encoding failures.
pub(all) suberror MultipartError {
  InvalidBoundary(String)
  BoundaryCollision
  InvalidHeaderValue(String)
} derive(Debug)

///|
/// Formats a multipart failure for debugging.
pub extend MultipartError with @debug.Debug::{to_repr}

///|
fn is_boundary_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() ||
  c.is_ascii_digit() ||
  (match c {
    '\''
    | '('
    | ')'
    | '+'
    | '_'
    | ','
    | '-'
    | '.'
    | '/'
    | ':'
    | '='
    | '?'
    | ' ' => true
    _ => false
  })
}

///|
fn boundary_needs_quotes(boundary : String) -> Bool {
  boundary
  .iter()
  .any(c => {
    match c {
      '(' | ')' | ',' | '/' | ':' | '=' | '?' | ' ' => true
      _ => false
    }
  })
}

///|
fn validate_boundary(boundary : String) -> Unit raise MultipartError {
  if boundary.length() == 0 ||
    boundary.length() > 70 ||
    boundary.iter().any(c => !is_boundary_char(c)) ||
    boundary.has_suffix(" ") {
    raise InvalidBoundary(boundary)
  }
}

///|
fn append_bytes(output : Array[Byte], bytes : Bytes) -> Unit {
  output.push_iter(bytes.iter())
}

///|
fn append_text(output : Array[Byte], text : String) -> Unit {
  append_bytes(output, @utf8.encode(text))
}

///|
fn append_escaped_parameter(output : Array[Byte], value : String) -> Unit {
  for byte in @utf8.encode(value) {
    match byte.to_int() {
      34 => append_bytes(output, b"%22")
      13 => append_bytes(output, b"%0D")
      10 => append_bytes(output, b"%0A")
      _ => output.push(byte)
    }
  }
}

///|
fn body_collides(body : Bytes, delimiter : Bytes, embedded : Bytes) -> Bool {
  body.has_prefix(delimiter[:]) || body.find(embedded[:]) is Some(_)
}

///|
/// Encodes fields as multipart/form-data and returns its Content-Type value and
/// byte-exact body.
///
/// ```mbt check
/// test {
///   let (content_type, body) = @multipart.encode(
///     [@multipart.Part::text("message", "hello")],
///     "example",
///   )
///   assert_eq(content_type, "multipart/form-data; boundary=example")
///   assert_true(body.has_suffix(b"--example--\r\n"[:]))
/// }
/// ```
pub fn encode(
  parts : Array[Part],
  boundary : String,
) -> (String, Bytes) raise MultipartError {
  let (content_type, segments) = encode_segments(parts, boundary)
  let output : Array[Byte] = []
  for segment in segments {
    append_bytes(output, segment)
  }
  (content_type, Bytes::from_array(output))
}

///|
/// Encodes fields like `encode`, but returns the body as ordered segments
/// instead of one buffer: the framing between parts, and each part's body
/// exactly as supplied, not copied. The segments concatenated are the body
/// `encode` returns, so a host can stream a large upload without building it
/// in memory first.
///
/// ```mbt check
/// test {
///   let file = b"\x00\x01"
///   let (_, segments) = @multipart.encode_segments(
///     [@multipart.Part::file("upload", "a.bin", "application/octet-stream", file)],
///     "example",
///   )
///   assert_eq(segments.length(), 3)
///   assert_true(physical_equal(segments[1], file))
/// }
/// ```
pub fn encode_segments(
  parts : Array[Part],
  boundary : String,
) -> (String, Array[Bytes]) raise MultipartError {
  validate_boundary(boundary)
  let delimiter = @utf8.encode("--" + boundary)
  let embedded = @utf8.encode("\r\n--" + boundary)
  for part in parts {
    if part.content_type is Some(content_type) &&
      (content_type.contains("\r") || content_type.contains("\n")) {
      raise InvalidHeaderValue(content_type)
    }
    if body_collides(part.body, delimiter, embedded) {
      raise BoundaryCollision
    }
  }
  let segments : Array[Bytes] = []
  let framing : Array[Byte] = []
  for part in parts {
    append_text(framing, "--" + boundary + "\r\n")
    append_text(framing, "Content-Disposition: form-data; name=\"")
    append_escaped_parameter(framing, part.name)
    append_text(framing, "\"")
    if part.filename is Some(filename) {
      append_text(framing, "; filename=\"")
      append_escaped_parameter(framing, filename)
      append_text(framing, "\"")
    }
    append_text(framing, "\r\n")
    if part.content_type is Some(content_type) {
      append_text(framing, "Content-Type: " + content_type + "\r\n")
    }
    append_text(framing, "\r\n")
    if !part.body.is_empty() {
      segments.push(Bytes::from_array(framing))
      framing.clear()
      segments.push(part.body)
    }
    append_text(framing, "\r\n")
  }
  append_text(framing, "--" + boundary + "--\r\n")
  segments.push(Bytes::from_array(framing))
  let parameter = if boundary_needs_quotes(boundary) {
    "\"" + boundary + "\""
  } else {
    boundary
  }
  ("multipart/form-data; boundary=" + parameter, segments)
}

///|
/// Creates a 40-character boundary from 32 base-36 random digits.
/// Values outside the random function's `[0, 1)` contract are clamped.
///
/// ```mbt check
/// test {
///   assert_eq(
///     @multipart.make_boundary(() => 0.0),
///     "mbt-sdk-00000000000000000000000000000000",
///   )
/// }
/// ```
pub fn make_boundary(random : () -> Double) -> String {
  let alphabet = b"0123456789abcdefghijklmnopqrstuvwxyz"
  let result = StringBuilder()
  result.write_string("mbt-sdk-")
  for _ in 0..<32 {
    let value = random()
    let index = if value.is_nan() || value <= 0.0 {
      0
    } else if value >= 1.0 {
      35
    } else {
      (value * 36.0).floor().to_int()
    }
    result.write_char(alphabet[index].to_char())
  }
  result.to_string()
}

///|
/// Returns an independent request with an encoded multipart body and replaces
/// every existing Content-Type value.
///
/// ```mbt check
/// test {
///   let request = @http.Request::post("/upload").header("x-id", "42")
///   let result = @multipart.apply(
///     request,
///     [@multipart.Part::text("message", "hello")],
///     "example",
///   )
///   assert_eq(
///     result.headers.get("content-type"),
///     Some("multipart/form-data; boundary=example"),
///   )
///   assert_eq(request.headers.get("content-type"), None)
/// }
/// ```
pub fn apply(
  request : @http.Request,
  parts : Array[Part],
  boundary : String,
) -> @http.Request raise MultipartError {
  let (content_type, body) = encode(parts, boundary)
  let result = request.body_bytes(body)
  result.headers.set("content-type", content_type)
  result
}
