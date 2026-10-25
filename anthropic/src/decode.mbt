///|
fn content_block_from_generated(block : @gen.ContentBlock) -> ContentBlock {
  match block {
    @gen.ContentBlock::Text(text) => Text(text.text)
    @gen.ContentBlock::Thinking(thinking) =>
      Thinking(thinking=thinking.thinking, signature=thinking.signature)
    @gen.ContentBlock::RedactedThinking(redacted) =>
      RedactedThinking(redacted.data)
    @gen.ContentBlock::ToolUse(tool_use) =>
      ToolUse(id=tool_use.id, name=tool_use.name, input=tool_use.input)
    @gen.ContentBlock::Unknown(kind, value) => Other(kind, value)
    other => {
      let value = other.to_json()
      Other(string_field(value, "type"), value)
    }
  }
}

///|
fn message_response_from_generated(
  message : @gen.Message,
  raw : Json,
) -> MessageResponse {
  {
    id: message.id,
    model: message.model,
    role: Assistant,
    content: message.content.map(content_block_from_generated),
    stop_reason: message.stop_reason,
    usage: message.usage,
    message,
    raw,
  }
}

///|
fn decode_message_response(
  value : Json,
) -> MessageResponse raise @json.JsonDecodeError {
  let message : @gen.Message = @json.from_json(value)
  message_response_from_generated(message, value)
}

///|
fn api_error_from_generated(error : @gen.ErrorResponseError) -> ApiErrorBody {
  match error {
    @gen.ErrorResponseError::ApiError(body) =>
      { type_: body.type_, message: body.message, }
    @gen.ErrorResponseError::AuthenticationError(body) =>
      { type_: body.type_, message: body.message, }
    @gen.ErrorResponseError::BillingError(body) =>
      { type_: body.type_, message: body.message, }
    @gen.ErrorResponseError::InvalidRequestError(body) =>
      { type_: body.type_, message: body.message, }
    @gen.ErrorResponseError::NotFoundError(body) =>
      { type_: body.type_, message: body.message, }
    @gen.ErrorResponseError::OverloadedError(body) =>
      { type_: body.type_, message: body.message, }
    @gen.ErrorResponseError::PermissionError(body) =>
      { type_: body.type_, message: body.message, }
    @gen.ErrorResponseError::RateLimitError(body) =>
      { type_: body.type_, message: body.message, }
    @gen.ErrorResponseError::TimeoutError(body) =>
      { type_: body.type_, message: body.message, }
    @gen.ErrorResponseError::Unknown(kind, value) =>
      { type_: kind, message: string_field(value, "message"), }
    // An error type added to the spec after this layer was written.
    @gen.ErrorResponseError::.. as other => {
      let value = other.to_json()
      {
        type_: string_field(value, "type"),
        message: string_field(value, "message"),
      }
    }
  }
}

///|
/// `{"type":"error","error":{...}}`: the body of every HTTP error and of the
/// stream `error` event. The generated `ErrorResponse` elides the constant
/// `type`, so the envelope is checked here before its `error` is decoded.
priv struct ApiErrorEnvelopeJson(ApiErrorBody)

///|
impl @json.FromJson for ApiErrorEnvelopeJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let kind : String = @sdkjson.field(obj, "type", path)
  if kind != "error" {
    raise @json.JsonDecodeError((path.add_key("type"), "expected error"))
  }
  let error : @gen.ErrorResponseError = @sdkjson.field(obj, "error", path)
  ApiErrorEnvelopeJson(api_error_from_generated(error))
}

///|
fn decode_error_envelope(
  value : Json,
) -> ApiErrorBody raise @json.JsonDecodeError {
  let envelope : ApiErrorEnvelopeJson = @json.from_json(value)
  envelope.0
}

///|
fn string_field(value : Json, key : String) -> String {
  match json_field(value, key) {
    Some(String(text)) => text
    _ => ""
  }
}

///|
fn json_field(value : Json, key : String) -> Json? {
  match value {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
fn message_event_from_generated(
  event : MessageStreamEvent,
  raw : Json,
) -> MessageEvent raise @json.JsonDecodeError {
  match event {
    @gen.MessageStreamEvent::MessageStart(start) => {
      let raw_message = json_field(raw, "message").unwrap_or(
        start.message.to_json(),
      )
      MessageStart(message_response_from_generated(start.message, raw_message))
    }
    @gen.MessageStreamEvent::ContentBlockStart(start) => {
      let block : @gen.ContentBlock = @json.from_json(
        start.content_block.to_json(),
      )
      ContentBlockStart(
        index=start.index,
        block=content_block_from_generated(block),
      )
    }
    @gen.MessageStreamEvent::ContentBlockDelta(delta) =>
      match delta.delta {
        @gen.ContentBlockDeltaEventDelta::TextDelta(text) =>
          TextDelta(index=delta.index, text=text.text)
        @gen.ContentBlockDeltaEventDelta::ThinkingDelta(thinking) =>
          ThinkingDelta(index=delta.index, thinking=thinking.thinking)
        @gen.ContentBlockDeltaEventDelta::SignatureDelta(signature) =>
          SignatureDelta(index=delta.index, signature=signature.signature)
        @gen.ContentBlockDeltaEventDelta::InputJsonDelta(json) =>
          InputJsonDelta(index=delta.index, partial_json=json.partial_json)
        @gen.ContentBlockDeltaEventDelta::CitationsDelta(_)
        | @gen.ContentBlockDeltaEventDelta::Unknown(_, _)
        | @gen.ContentBlockDeltaEventDelta::.. =>
          Other("content_block_delta", raw)
      }
    @gen.MessageStreamEvent::ContentBlockStop(stop) =>
      ContentBlockStop(index=stop.index)
    @gen.MessageStreamEvent::MessageDelta(delta) =>
      MessageDelta(delta=delta.delta, usage=delta.usage)
    @gen.MessageStreamEvent::MessageStop(_) => MessageStop
    @gen.MessageStreamEvent::Unknown("ping", _) => Ping
    @gen.MessageStreamEvent::Unknown("error", _) =>
      Error(decode_error_envelope(raw))
    @gen.MessageStreamEvent::Unknown(kind, _) => Other(kind, raw)
    // An event added to the spec after this layer was written stays `Other`,
    // as it was before regeneration.
    @gen.MessageStreamEvent::.. => Other(string_field(raw, "type"), raw)
  }
}

///|
fn decode_message_event(
  value : Json,
) -> MessageEvent raise @json.JsonDecodeError {
  let event : MessageStreamEvent = @json.from_json(value)
  message_event_from_generated(event, value)
}

///|
fn parse_json_body(body : Bytes) -> Json raise {
  @json.parse(@utf8.decode(body))
}

///|
fn decode_api_error_body(body : Bytes) -> ApiErrorBody raise {
  decode_error_envelope(parse_json_body(body))
}

///|
/// Extracts an Anthropic error envelope from an HTTP status failure.
/// Returns None for transport, decode, configuration, and malformed error bodies.
pub fn api_error(error : Error) -> ApiErrorBody? {
  let body = match error {
    @client.UnexpectedStatus(_, body~) => body
    _ => return None
  }
  try decode_api_error_body(body) catch {
    _ => None
  } noraise {
    value => Some(value)
  }
}
