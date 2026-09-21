///|
/// An HTTP request with a byte body. Builders copy headers before returning.
///
/// ```mbt check
/// test {
///   let request = @http.Request::post("/items")
///     .header("Accept", "application/json")
///     .body_text("hello")
///   assert_eq(request.body, b"hello")
/// }
/// ```
pub(all) struct Request {
  http_method : String
  url : String
  headers : Headers
  body : Bytes
}

///|
/// Creates a request with the supplied method, empty headers and an empty body.
pub fn Request::new(http_method : String, url : String) -> Request {
  { http_method, url, headers: Headers::new(), body: b"", }
}

///|
/// Creates a GET request.
pub fn Request::get(url : String) -> Request {
  Request::new("GET", url)
}

///|
/// Creates a POST request.
pub fn Request::post(url : String) -> Request {
  Request::new("POST", url)
}

///|
/// Creates a PUT request.
pub fn Request::put(url : String) -> Request {
  Request::new("PUT", url)
}

///|
/// Creates a PATCH request.
pub fn Request::patch(url : String) -> Request {
  Request::new("PATCH", url)
}

///|
/// Creates a DELETE request.
pub fn Request::delete(url : String) -> Request {
  Request::new("DELETE", url)
}

///|
/// Returns a new request with an appended header and independent headers.
pub fn Request::header(
  self : Request,
  name : String,
  value : String,
) -> Request {
  let headers = self.headers.copy()
  headers.append(name, value)
  { ..self, headers, }
}

///|
/// Returns a new request with the supplied bytes and independent headers.
pub fn Request::body_bytes(self : Request, body : Bytes) -> Request {
  { ..self, headers: self.headers.copy(), body, }
}

///|
/// Returns a new request whose body is the UTF-8 encoding of the text.
pub fn Request::body_text(self : Request, body : String) -> Request {
  self.body_bytes(@utf8.encode(body))
}

///|
/// Encodes JSON as UTF-8 and supplies application/json only if content-type is absent.
pub fn Request::json_body(self : Request, body : Json) -> Request {
  let request = self.body_text(body.stringify())
  if !request.headers.contains("content-type") {
    request.headers.set("content-type", "application/json")
  }
  request
}
