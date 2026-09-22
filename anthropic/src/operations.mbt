///|
fn decode_http_response(
  response : @http.Response,
) -> MessageResponse raise @runtime.SdkError {
  decode_message_response(parse_json_body(response.body)) catch {
    error =>
      raise @runtime.Decode(message=error.to_string(), body=response.body)
  }
}

///|
fn Anthropic::message_request(
  self : Anthropic,
  body : Json,
  stream : Bool,
) -> @http.Request {
  let request = @http.Request::post("/messages").header(
    "anthropic-version",
    self.version,
  )
  let request = if stream {
    request.header("accept", "text/event-stream")
  } else {
    request
  }
  request.json_body(body)
}

///|
/// Creates and buffers one message response.
pub async fn Anthropic::create_message(
  self : Anthropic,
  request : MessageRequest,
) -> MessageResponse raise @runtime.SdkError {
  let body = message_body(request, false)
  let response = self.client.send(
    self.message_request(body, false),
    bucket="messages",
  )
  decode_http_response(response)
}

///|
fn decode_stream_data(data : String) -> MessageEvent raise @runtime.SdkError {
  let body = @utf8.encode(data)
  decode_message_event(parse_json_body(body)) catch {
    error => raise @runtime.Decode(message=error.to_string(), body~)
  }
}

///|
/// Creates a streaming message and dispatches decoded events in arrival order.
/// The stream is read through EOF and closed after success or any failure.
pub async fn[E : Error] Anthropic::stream_message(
  self : Anthropic,
  request : MessageRequest,
  f : async (MessageEvent) -> Unit raise E,
) -> Unit {
  let body = message_body(request, true)
  let (_, stream) = self.client.send_stream(
    self.message_request(body, true),
    bucket="messages",
  )
  // Anthropic itself ends with message_stop and EOF, but OpenAI-compatible
  // gateways such as OpenRouter add an OpenAI-style `data: [DONE]` sentinel.
  // It carries no event, so it is skipped rather than decoded.
  @sse.each_event(stream, event => {
    if event.data != "[DONE]" {
      f(decode_stream_data(event.data))
    }
  })
}
