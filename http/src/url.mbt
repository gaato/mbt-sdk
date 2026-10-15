///|
/// Percent-encodes UTF-8 bytes, preserving only RFC 3986 unreserved bytes.
pub fn percent_encode(value : String) -> String {
  encode_url_bytes(value, false)
}

///|
/// Percent-encodes a multi-segment path, also preserving slash separators.
pub fn percent_encode_path(value : String) -> String {
  encode_url_bytes(value, true)
}

///|
fn encode_url_bytes(value : String, keep_slash : Bool) -> String {
  let hex = b"0123456789ABCDEF"
  let output : Array[Byte] = []
  for byte in @utf8.encode(value) {
    let code = byte.to_int()
    if (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) ||
      byte == b'-' ||
      byte == b'.' ||
      byte == b'_' ||
      byte == b'~' ||
      (keep_slash && byte == b'/') {
      output.push(byte)
    } else {
      output.push(b'%')
      output.push(hex[code >> 4])
      output.push(hex[code & 15])
    }
  }
  try! @utf8.decode(Bytes::from_array(output))
}

///|
/// Appends an encoded query pair, using ampersand if the URL contains `?`.
pub fn append_query(url : String, name : String, value : String) -> String {
  let separator = if url.contains("?") { "&" } else { "?" }
  url + separator + percent_encode(name) + "=" + percent_encode(value)
}
