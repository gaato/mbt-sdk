///|
/// Percent-encodes UTF-8 bytes, preserving only RFC 3986 unreserved bytes.
pub fn percent_encode(value : String) -> String {
  @percent.encode(value)
}

///|
/// Percent-encodes a multi-segment path, also preserving slash separators.
pub fn percent_encode_path(value : String) -> String {
  let builder = StringBuilder()
  for i, segment in value.split("/") {
    if i > 0 {
      builder.write_char('/')
    }
    builder.write_string(@percent.encode(segment))
  }
  builder.to_string()
}

///|
/// Appends an encoded query pair, using ampersand if the URL contains `?`.
pub fn append_query(url : String, name : String, value : String) -> String {
  let separator = if url.contains("?") { "&" } else { "?" }
  url + separator + percent_encode(name) + "=" + percent_encode(value)
}
