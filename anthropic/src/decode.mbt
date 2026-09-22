///|
fn role(
  value : Json,
  path : @json.JsonPath,
) -> Role raise @json.JsonDecodeError {
  guard value is String(raw) else {
    raise @json.JsonDecodeError((path, "expected string"))
  }
  match raw {
    "user" => User
    "assistant" => Assistant
    _ => raise @json.JsonDecodeError((path, "unknown role: " + raw))
  }
}

///|
fn stop_reason(
  value : Json,
  path : @json.JsonPath,
) -> StopReason raise @json.JsonDecodeError {
  @sdkjson.open_string(
    value,
    path,
    raw => {
      match raw {
        "end_turn" => Some(EndTurn)
        "max_tokens" => Some(MaxTokens)
        "stop_sequence" => Some(StopSequence)
        "tool_use" => Some(ToolUse)
        "refusal" => Some(Refusal)
        _ => None
      }
    },
    raw => Unknown(raw),
  )
}

///|
fn content_block(
  value : Json,
  path : @json.JsonPath,
) -> ContentBlock raise @json.JsonDecodeError {
  let obj = @sdkjson.expect_object(value, path)
  let kind : String = @sdkjson.field(obj, "type", path)
  match kind {
    "text" => Text(@sdkjson.field(obj, "text", path))
    "thinking" => Thinking(@sdkjson.field(obj, "thinking", path))
    "tool_use" =>
      ToolUse(
        id=@sdkjson.field(obj, "id", path),
        name=@sdkjson.field(obj, "name", path),
        input=@sdkjson.field(obj, "input", path),
      )
    _ => Other(kind, value)
  }
}

///|
priv struct ContentBlockJson(ContentBlock)

///|
impl @json.FromJson for ContentBlockJson with fn from_json(value, path) {
  ContentBlockJson(content_block(value, path))
}

///|
priv struct UsageJson(Usage)

///|
impl @json.FromJson for UsageJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  UsageJson({
    input_tokens: @sdkjson.field(obj, "input_tokens", path),
    output_tokens: @sdkjson.field(obj, "output_tokens", path),
  })
}

///|
priv struct MessageResponseJson(MessageResponse)

///|
impl @json.FromJson for MessageResponseJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let raw_role : Json = @sdkjson.field(obj, "role", path)
  let raw_content : Array[ContentBlockJson] = @sdkjson.field(
    obj, "content", path,
  )
  let raw_stop_reason : Json? = @sdkjson.opt_field(obj, "stop_reason", path)
  let usage : UsageJson = @sdkjson.field(obj, "usage", path)
  MessageResponseJson({
    id: @sdkjson.field(obj, "id", path),
    model: @sdkjson.field(obj, "model", path),
    role: role(raw_role, path.add_key("role")),
    content: raw_content.map(block => block.0),
    stop_reason: raw_stop_reason.map(value => {
      stop_reason(value, path.add_key("stop_reason"))
    }),
    usage: usage.0,
    raw: value,
  })
}

///|
fn decode_message_response(
  value : Json,
) -> MessageResponse raise @json.JsonDecodeError {
  let decoded : MessageResponseJson = @json.from_json(value)
  decoded.0
}

///|
priv struct ApiErrorJson(ApiErrorBody)

///|
impl @json.FromJson for ApiErrorJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  ApiErrorJson({
    type_: @sdkjson.field(obj, "type", path),
    message: @sdkjson.field(obj, "message", path),
  })
}

///|
priv struct ApiErrorEnvelopeJson(ApiErrorBody)

///|
impl @json.FromJson for ApiErrorEnvelopeJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let kind : String = @sdkjson.field(obj, "type", path)
  if kind != "error" {
    raise @json.JsonDecodeError((path.add_key("type"), "expected error"))
  }
  let error : ApiErrorJson = @sdkjson.field(obj, "error", path)
  ApiErrorEnvelopeJson(error.0)
}

///|
fn event_api_error(
  obj : Map[String, Json],
  path : @json.JsonPath,
) -> ApiErrorBody raise @json.JsonDecodeError {
  let error : ApiErrorJson = @sdkjson.field(obj, "error", path)
  error.0
}

///|
fn event_stop_reason(
  obj : Map[String, Json],
  path : @json.JsonPath,
) -> StopReason? raise @json.JsonDecodeError {
  let value : Json? = @sdkjson.opt_field(obj, "stop_reason", path)
  value.map(value => stop_reason(value, path.add_key("stop_reason")))
}

///|
fn message_delta(
  obj : Map[String, Json],
  path : @json.JsonPath,
) -> MessageEvent raise @json.JsonDecodeError {
  let delta_value : Json = @sdkjson.field(obj, "delta", path)
  let delta_path = path.add_key("delta")
  let delta = @sdkjson.expect_object(delta_value, delta_path)
  let usage : Json? = @sdkjson.opt_field(obj, "usage", path)
  let output_tokens = match usage {
    None => None
    Some(value) => {
      let usage_path = path.add_key("usage")
      let usage_obj = @sdkjson.expect_object(value, usage_path)
      @sdkjson.opt_field(usage_obj, "output_tokens", usage_path)
    }
  }
  MessageDelta(stop_reason=event_stop_reason(delta, delta_path), output_tokens~)
}

///|
fn content_block_delta(
  value : Json,
  obj : Map[String, Json],
  path : @json.JsonPath,
) -> MessageEvent raise @json.JsonDecodeError {
  let index : Int = @sdkjson.field(obj, "index", path)
  let delta_value : Json = @sdkjson.field(obj, "delta", path)
  let delta_path = path.add_key("delta")
  let delta = @sdkjson.expect_object(delta_value, delta_path)
  let kind : String = @sdkjson.field(delta, "type", delta_path)
  match kind {
    "text_delta" =>
      TextDelta(index~, text=@sdkjson.field(delta, "text", delta_path))
    "thinking_delta" =>
      ThinkingDelta(
        index~,
        thinking=@sdkjson.field(delta, "thinking", delta_path),
      )
    "input_json_delta" =>
      InputJsonDelta(
        index~,
        partial_json=@sdkjson.field(delta, "partial_json", delta_path),
      )
    _ => Other("content_block_delta", value)
  }
}

///|
priv struct MessageEventJson(MessageEvent)

///|
impl @json.FromJson for MessageEventJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let kind : String = @sdkjson.field(obj, "type", path)
  let event = match kind {
    "message_start" => {
      let message : MessageResponseJson = @sdkjson.field(obj, "message", path)
      MessageStart(message.0)
    }
    "content_block_start" => {
      let block : ContentBlockJson = @sdkjson.field(obj, "content_block", path)
      ContentBlockStart(index=@sdkjson.field(obj, "index", path), block=block.0)
    }
    "content_block_delta" => content_block_delta(value, obj, path)
    "content_block_stop" =>
      ContentBlockStop(index=@sdkjson.field(obj, "index", path))
    "message_delta" => message_delta(obj, path)
    "message_stop" => MessageStop
    "ping" => Ping
    "error" => Error(event_api_error(obj, path))
    _ => Other(kind, value)
  }
  MessageEventJson(event)
}

///|
fn decode_message_event(
  value : Json,
) -> MessageEvent raise @json.JsonDecodeError {
  let decoded : MessageEventJson = @json.from_json(value)
  decoded.0
}

///|
fn parse_json_body(body : Bytes) -> Json raise {
  @json.parse(@utf8.decode(body))
}

///|
fn decode_api_error_body(body : Bytes) -> ApiErrorBody raise {
  let envelope : ApiErrorEnvelopeJson = @json.from_json(parse_json_body(body))
  envelope.0
}

///|
/// Extracts an Anthropic error envelope from an HTTP status failure.
/// Returns None for transport, decode, configuration, and malformed error bodies.
pub fn api_error(error : @runtime.SdkError) -> ApiErrorBody? {
  let body = match error {
    @runtime.Status(body~, ..) | @runtime.RateLimited(body~, ..) => body
    _ => return None
  }
  try decode_api_error_body(body) catch {
    _ => None
  } noraise {
    value => Some(value)
  }
}
