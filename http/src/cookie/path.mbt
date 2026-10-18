///|
/// RFC 6265 §5.1.4 default-path: the request path up to, not including, its
/// right-most `/`, or `/` when that would leave nothing.
fn default_path(request_path : String) -> String {
  guard request_path.has_prefix("/") else { return "/" }
  match request_path.rev_find("/") {
    Some(last) if last > 0 => request_path[:last].to_owned()
    _ => "/"
  }
}

///|
/// RFC 6265 §5.1.4 path-match: the cookie path is the request path, or a
/// prefix of it that ends with `/` or is followed by `/`.
fn path_match(request_path : String, cookie_path : String) -> Bool {
  request_path == cookie_path ||
  (
    request_path.has_prefix(cookie_path) &&
    (
      cookie_path.has_suffix("/") ||
      request_path[cookie_path.length():].has_prefix("/")
    )
  )
}
