///|
// The raw reply is kept for generic send and for bounded diagnostic excerpts.
// Typed operations and paginators consume the same parse used to inspect success.
async fn __CLIENT__::read_envelope(
  self : __CLIENT__,
  request : @http.Request,
  operation~ : String,
) -> Result[(@client.Reply[Bytes], Result[Json, String]), Failure] {
  match self.send_buffered(request, operation~) {
    Err(error) => Err(error)
    Ok(reply) => {
      let parsed = envelope_json(reply.body)
      if parsed is Ok({ __SUCCESS__: False, .. }) {
        let head : @http.ResponseHead = { status: reply.status, headers: reply.headers }
        Err(Http(envelope_failure(operation, head, reply.body, parsed)))
      } else {
        Ok((reply, parsed))
      }
    }
  }
}

///|
/// Returns buffered bytes and metadata, classifying HTTP and false success envelopes.
pub async fn __CLIENT__::send(
  self : __CLIENT__,
  request : @http.Request,
  operation~ : String = self.infer_operation(request),
) -> Result[@client.Reply[Bytes], Failure] {
  self.read_envelope(request, operation~).map(value => value.0)
}

///|
fn envelope_decode_failure(reply : @client.Reply[Bytes], message : String) -> Failure {
  let head : @http.ResponseHead = { status: reply.status, headers: reply.headers }
  Decode(@client.Deserialization(head, message~, body=reply.body[:reply.body.length().min(@client.max_error_body)].to_owned()))
}

///|
async fn[T] __CLIENT__::call_envelope(
  self : __CLIENT__,
  request : @http.Request,
  decode : (Json) -> T raise @json.JsonDecodeError,
  operation~ : String,
) -> Result[T, Failure] {
  match self.read_envelope(request, operation~) {
    Err(error) => Err(error)
    Ok((reply, Err(message))) => Err(envelope_decode_failure(reply, message))
    Ok((reply, Ok(value))) =>
      Ok(decode(value)) catch {
        error => Err(envelope_decode_failure(reply, error.to_string()))
      }
  }
}
