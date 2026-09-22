///|
priv struct RequiredResponseStatusJson(String)

///|
impl @json.FromJson for RequiredResponseStatusJson with fn from_json(
  value,
  path,
) {
  let obj = @sdkjson.expect_object(value, path)
  RequiredResponseStatusJson(@sdkjson.field(obj, "status", path))
}

///|
fn response_status_from_generated(
  status : @gen.ResponseStatus?,
  raw : String,
) -> ResponseStatus {
  match status {
    Some(@gen.Completed) => Completed
    Some(@gen.Failed) => Failed
    Some(@gen.InProgress) => InProgress
    Some(@gen.Incomplete) => Incomplete
    Some(@gen.Unknown(value)) => Unknown(value)
    None => Unknown(raw)
  }
}

///|
fn chat_usage_from_generated(usage : @gen.CompletionUsage) -> Usage {
  {
    input_tokens: usage.prompt_tokens,
    output_tokens: usage.completion_tokens,
    total_tokens: usage.total_tokens,
  }
}

///|
fn tool_call_from_generated(
  call : @gen.ChatCompletionMessageToolCall,
) -> ToolCall {
  { id: call.id, name: call.function.name, arguments: call.function.arguments, }
}

///|
fn chat_finish_reason(
  reason : @gen.CreateChatCompletionResponseChoicesItemFinishReason,
) -> FinishReason {
  match reason {
    @gen.Stop => Stop
    @gen.Length => Length
    @gen.ToolCalls => ToolCalls
    @gen.ContentFilter => ContentFilter
    @gen.FunctionCall => Unknown("function_call")
    @gen.Unknown(value) => Unknown(value)
  }
}

///|
fn chat_stream_finish_reason(
  reason : @gen.CreateChatCompletionStreamResponseChoicesItemFinishReason,
) -> FinishReason {
  match reason {
    @gen.Stop => Stop
    @gen.Length => Length
    @gen.ToolCalls => ToolCalls
    @gen.ContentFilter => ContentFilter
    @gen.FunctionCall => Unknown("function_call")
    @gen.Unknown(value) => Unknown(value)
  }
}

///|
fn decode_chat_completion(
  response : @http.Response,
) -> ChatCompletion raise @runtime.SdkError {
  let raw = response.json() catch {
    error =>
      raise @runtime.Decode(message=error.to_string(), body=response.body)
  }
  let generated = @gen.create_chat_completion_decode_json(raw) catch {
    error =>
      raise @runtime.Decode(message=error.to_string(), body=response.body)
  }
  guard generated.choices.get(0) is Some(choice) else {
    raise @runtime.Decode(
      message="chat completion has no choices",
      body=response.body,
    )
  }
  {
    id: generated.id,
    model: generated.model,
    text: choice.message.content.unwrap_or(""),
    finish_reason: Some(chat_finish_reason(choice.finish_reason)),
    usage: generated.usage.map(chat_usage_from_generated),
    tool_calls: choice.message.tool_calls
    .map(calls => calls.map(tool_call_from_generated))
    .unwrap_or([]),
    raw,
  }
}

///|
fn reasoning_delta_at(value : Json, index : Int) -> String? {
  guard value is Object(root) else { return None }
  guard root.get("choices") is Some(Array(choices)) else { return None }
  guard choices.get(index) is Some(Object(choice)) else { return None }
  guard choice.get("delta") is Some(Object(delta)) else { return None }
  match delta.get("reasoning_content") {
    Some(String(text)) => Some(text)
    _ =>
      match delta.get("reasoning") {
        Some(String(text)) => Some(text)
        _ => None
      }
  }
}

///|
fn chat_chunk_kind(value : Json) -> String {
  guard value is Object(root) else { return "chat.completion.chunk" }
  match root.get("object") {
    Some(String(kind)) => kind
    _ => "chat.completion.chunk"
  }
}

///|
fn decode_chat_chunk(
  value : Json,
) -> Array[ChatEvent] raise @json.JsonDecodeError {
  let chunk : @gen.CreateChatCompletionStreamResponse = @json.from_json(value)
  let events : Array[ChatEvent] = []
  for index, choice in chunk.choices {
    match choice.delta.content {
      @sdkjson.Value(text) => events.push(Delta(text))
      _ => ()
    }
    if reasoning_delta_at(value, index) is Some(text) {
      events.push(ReasoningDelta(text))
    }
    if index == 0 && choice.delta.tool_calls is Some(calls) {
      for call in calls {
        let name = match call.function {
          Some(function) => function.name
          None => None
        }
        let arguments = match call.function {
          Some(function) => function.arguments.unwrap_or("")
          None => ""
        }
        events.push(
          ToolCallDelta(index=call.index, id=call.id, name~, arguments~),
        )
      }
    }
    if choice.finish_reason is Some(reason) {
      events.push(Finished(chat_stream_finish_reason(reason)))
    }
  }
  match chunk.usage {
    @sdkjson.Value(usage) =>
      events.push(Usage(chat_usage_from_generated(usage)))
    _ => ()
  }
  if events.is_empty() {
    events.push(Other(chat_chunk_kind(value), value))
  }
  events
}

///|
fn output_text_from_generated(output : Array[@gen.OutputItem]) -> String {
  let result = StringBuilder()
  for item in output {
    match item {
      @gen.Message(message) =>
        for content in message.content {
          if content is @gen.OutputText(part) {
            result.write_string(part.text)
          }
        }
      _ => ()
    }
  }
  result.to_string()
}

///|
fn response_tool_calls(output : Array[@gen.OutputItem]) -> Array[ToolCall] {
  let calls : Array[ToolCall] = []
  for item in output {
    if item is @gen.FunctionCall(call) {
      calls.push({
        id: call.call_id,
        name: call.name,
        arguments: call.arguments,
      })
    }
  }
  calls
}

///|
fn response_from_generated(
  response : @gen.Response,
  raw : Json,
) -> Response raise @json.JsonDecodeError {
  let status : RequiredResponseStatusJson = @json.from_json(raw)
  {
    id: response.id,
    status: response_status_from_generated(response.status, status.0),
    model: response.model,
    output_text: output_text_from_generated(response.output),
    usage: response.usage.map(usage => {
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
    }),
    tool_calls: response_tool_calls(response.output),
    raw,
  }
}

///|
priv struct ResponseEventJson(Json)

///|
impl @json.FromJson for ResponseEventJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  ResponseEventJson(@sdkjson.field(obj, "response", path))
}

///|
priv struct ResponseEventTypeJson(String)

///|
impl @json.FromJson for ResponseEventTypeJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  ResponseEventTypeJson(@sdkjson.field(obj, "type", path))
}

///|
priv struct ApiErrorJson(ApiErrorBody)

///|
impl @json.FromJson for ApiErrorJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  ApiErrorJson({
    message: @sdkjson.field(obj, "message", path),
    type_: @sdkjson.opt_field(obj, "type", path),
    param: @sdkjson.opt_field(obj, "param", path),
    code: @sdkjson.opt_field(obj, "code", path),
  })
}

///|
priv struct ApiErrorEnvelopeJson(ApiErrorBody)

///|
impl @json.FromJson for ApiErrorEnvelopeJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let error : ApiErrorJson = @sdkjson.field(obj, "error", path)
  ApiErrorEnvelopeJson(error.0)
}

///|
fn decode_response(
  response : @http.Response,
) -> Response raise @runtime.SdkError {
  let raw = response.json() catch {
    error =>
      raise @runtime.Decode(message=error.to_string(), body=response.body)
  }
  let generated = @gen.create_response_decode_json(raw) catch {
    error =>
      raise @runtime.Decode(message=error.to_string(), body=response.body)
  }
  response_from_generated(generated, raw) catch {
    error =>
      raise @runtime.Decode(message=error.to_string(), body=response.body)
  }
}

///|
fn response_event_from_generated(
  event : @gen.ResponseStreamEvent,
  raw : Json,
) -> ResponseEvent raise @json.JsonDecodeError {
  match event {
    @gen.ResponseCreated(event) => {
      let response : ResponseEventJson = @json.from_json(raw)
      Created(response_from_generated(event.response, response.0))
    }
    @gen.ResponseInProgress(event) => {
      let response : ResponseEventJson = @json.from_json(raw)
      InProgress(response_from_generated(event.response, response.0))
    }
    @gen.ResponseCompleted(event) => {
      let response : ResponseEventJson = @json.from_json(raw)
      Completed(response_from_generated(event.response, response.0))
    }
    @gen.ResponseFailed(event) => {
      let response : ResponseEventJson = @json.from_json(raw)
      Failed(response_from_generated(event.response, response.0))
    }
    @gen.ResponseIncomplete(event) => {
      let response : ResponseEventJson = @json.from_json(raw)
      Incomplete(response_from_generated(event.response, response.0))
    }
    @gen.ResponseOutputTextDelta(event) => OutputTextDelta(event.delta)
    @gen.ResponseOutputTextDone(event) => OutputTextDone(event.text)
    @gen.ResponseFunctionCallArgumentsDelta(event) =>
      FunctionCallArgumentsDelta(item_id=event.item_id, delta=event.delta)
    @gen.ResponseFunctionCallArgumentsDone(event) =>
      FunctionCallArgumentsDone(
        item_id=event.item_id,
        arguments=event.arguments,
      )
    @gen.Error(event) =>
      Error({
        message: event.message,
        type_: None,
        param: event.param,
        code: event.code,
      })
    @gen.Unknown(kind, unknown_raw) => Other(kind, unknown_raw)
    _ => {
      let kind : ResponseEventTypeJson = @json.from_json(raw)
      Other(kind.0, raw)
    }
  }
}

///|
fn decode_response_event(
  value : Json,
) -> ResponseEvent raise @json.JsonDecodeError {
  let generated : @gen.ResponseStreamEvent = @json.from_json(value)
  response_event_from_generated(generated, value)
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
/// Extracts a standard OpenAI error body from an HTTP status failure.
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
