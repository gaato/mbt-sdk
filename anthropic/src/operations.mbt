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
/// Creates and buffers one message.
pub async fn Anthropic::create_message(
  self : Anthropic,
  request : MessageRequest,
) -> MessageResponse raise @runtime.SdkError {
  let (params, body) = message_body(request, false)
  let response = self.client.send(
    @gen.messages_post_request(params, anthropic_version=self.version).json_body(
      body,
    ),
    bucket="messages",
  )
  decode_http_response(response)
}

///|
/// Creates and buffers one message from a generated request, for parameters the
/// facade request does not model. `stream` is ignored.
pub async fn Anthropic::create_message_params(
  self : Anthropic,
  params : CreateMessageParams,
) -> @gen.Message raise @runtime.SdkError {
  let params = { ..params, stream: None, }
  let response = self.client.send(
    @gen.messages_post_request(params, anthropic_version=self.version),
    bucket="messages",
  )
  @gen.messages_post_decode(response)
}

///|
fn decode_stream_data(data : String) -> MessageEvent raise @runtime.SdkError {
  let body = @utf8.encode(data)
  decode_message_event(parse_json_body(body)) catch {
    error => raise @runtime.Decode(message=error.to_string(), body~)
  }
}

///|
fn decode_stream_event(
  data : String,
) -> MessageStreamEvent raise @runtime.SdkError {
  let body = @utf8.encode(data)
  let event : MessageStreamEvent = @json.from_json(parse_json_body(body)) catch {
    error => raise @runtime.Decode(message=error.to_string(), body~)
  }
  event
}

///|
async fn[E : Error] Anthropic::each_stream_data(
  self : Anthropic,
  request : @http.Request,
  f : async (String) -> Unit raise E,
) -> Unit {
  let (_, stream) = self.client.send_stream(
    request.header("accept", "text/event-stream"),
    bucket="messages",
  )
  // Anthropic itself ends with message_stop and EOF, but OpenAI-compatible
  // gateways such as OpenRouter add an OpenAI-style `data: [DONE]` sentinel.
  // It carries no event, so it is skipped rather than decoded.
  @sse.each_event(stream, event => if event.data != "[DONE]" { f(event.data) })
}

///|
/// Creates a streaming message and dispatches decoded events in arrival order.
/// The stream is read through EOF and closed after success or any failure.
pub async fn[E : Error] Anthropic::stream_message(
  self : Anthropic,
  request : MessageRequest,
  f : async (MessageEvent) -> Unit raise E,
) -> Unit {
  let (params, body) = message_body(request, true)
  self.each_stream_data(
    @gen.messages_post_request(params, anthropic_version=self.version).json_body(
      body,
    ),
    data => f(decode_stream_data(data)),
  )
}

///|
/// Creates a streaming message from a generated request and dispatches the
/// generated events. `stream` is forced on; `ping`, `error` and future event
/// kinds arrive as `MessageStreamEvent::Unknown`.
pub async fn[E : Error] Anthropic::stream_message_params(
  self : Anthropic,
  params : CreateMessageParams,
  f : async (MessageStreamEvent) -> Unit raise E,
) -> Unit {
  let params = { ..params, stream: Some(true), }
  self.each_stream_data(
    @gen.messages_post_request(params, anthropic_version=self.version),
    data => f(decode_stream_event(data)),
  )
}

///|
/// Counts the input tokens of a request without creating a message.
pub async fn Anthropic::count_tokens(
  self : Anthropic,
  request : MessageRequest,
) -> Int raise @runtime.SdkError {
  let (params, body) = count_tokens_body(request)
  let response = self.client.send(
    @gen.messages_count_tokens_post_request(
      params,
      anthropic_version=self.version,
    ).json_body(body),
    bucket="messages",
  )
  @gen.messages_count_tokens_post_decode(response).input_tokens
}

///|
/// Lists one page of models. Follow `has_more` with `after_id=last_id`.
pub async fn Anthropic::list_models(
  self : Anthropic,
  limit? : Int,
  after_id? : String,
  before_id? : String,
) -> ListResponseModelInfo raise @runtime.SdkError {
  let response = self.client.send(
    @gen.models_list_request(
      limit?,
      after_id?,
      before_id?,
      anthropic_version=self.version,
    ),
    bucket="models",
  )
  @gen.models_list_decode(response)
}

///|
/// Retrieves one model by identifier or alias.
pub async fn Anthropic::retrieve_model(
  self : Anthropic,
  model_id : String,
) -> ModelInfo raise @runtime.SdkError {
  let response = self.client.send(
    @gen.models_get_request(model_id, anthropic_version=self.version),
    bucket="models",
  )
  @gen.models_get_decode(response)
}
