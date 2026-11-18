///|
/// A message reported by a structured API error envelope.
#derive(@debug.Debug)
pub(all) struct EnvelopeMessage {
  code : Int32
  message : String
  documentation_url : String?
  source_pointer : String?
}

///|
pub extend EnvelopeMessage with @debug.Debug::{to_repr}

///|
/// Response failure with the original head, bounded body and any decoded messages.
#derive(@debug.Debug)
pub(all) struct HttpFailure {
  operation : String
  head : @http.ResponseHead
  body : Bytes
  errors : Array[EnvelopeMessage]
  messages : Array[EnvelopeMessage]
}

///|
pub extend HttpFailure with @debug.Debug::{to_repr}

///|
/// Transport failures retain their kind and phase. Cancellation propagates.
#derive(@debug.Debug)
#non_exhaustive
pub(all) enum Failure {
  Http(HttpFailure)
  Transport(@http.TransportError)
  Decode(@client.ResponseFailure)
  Validation(operation~ : String, parameter~ : String, message~ : String)
}

///|
pub extend Failure with @debug.Debug::{to_repr}

///|
fn envelope_json(body : Bytes) -> Result[Json, String] {
  Ok(@json.parse(@utf8.decode(body))) catch { error => Err(error.to_string()) }
}

///|
fn envelope_messages(value : Result[Json, String], field : String) -> Array[EnvelopeMessage] {
  guard value is Ok(Object(fields)) && fields.get(field) is Some(Array(entries)) else { return [] }
  entries.filter_map(entry => {
    guard entry is { "code": code, "message": String(message), .. } else { return None }
    let code : Int32 = @json.from_json(code) catch { _ => return None }
    let documentation_url = if entry is { "documentation_url": String(url), .. } { Some(url) } else { None }
    let source_pointer = if entry is { "source": { "pointer": String(pointer), .. }, .. } { Some(pointer) } else { None }
    Some({ code, message, documentation_url, source_pointer })
  })
}

///|
fn envelope_failure(operation : String, head : @http.ResponseHead, body : Bytes, value : Result[Json, String]) -> HttpFailure {
  {
    operation,
    head,
    body: body[:body.length().min(@client.max_error_body)].to_owned(),
    errors: envelope_messages(value, __ERRORS__),
    messages: envelope_messages(value, __MESSAGES__),
  }
}
