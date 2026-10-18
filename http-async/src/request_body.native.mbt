///|
// Native/Wasm Client writes the body to the connection as it is given, framed
// by the `Content-Length` the transport declares or else chunked, so a stream
// body is never held in memory.
let declares_content_length : Bool = true

///|
let buffered_stream_limit : Int64? = None
