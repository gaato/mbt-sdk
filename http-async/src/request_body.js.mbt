///|
// JS Client is fetch, which frames the body itself. moonbitlang/async 0.22's
// `Client::write` appends to an in-memory buffer that `end_request` hands to
// fetch whole, so a stream body is read into memory before anything is sent,
// up to `buffered_stream_limit`. Streaming it instead (a ReadableStream body
// with `duplex: "half"`) would need a fetch call of the transport's own and a
// buffered fallback anyway: Node 18.13+ streams request bodies, Chromium only
// over HTTP/2 or later, and Firefox and Safari releases not at all.
let declares_content_length : Bool = false

///|
/// 16 MiB.
let buffered_stream_limit : Int64? = Some(16L * 1024 * 1024)
