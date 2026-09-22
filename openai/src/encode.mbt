///|
fn is_response_key(key : String) -> Bool {
  match key {
    "model"
    | "input"
    | "instructions"
    | "max_output_tokens"
    | "temperature"
    | "previous_response_id"
    | "stream" => true
    _ => false
  }
}

///|
fn is_chat_key(key : String) -> Bool {
  match key {
    "model"
    | "messages"
    | "max_tokens"
    | "temperature"
    | "stream"
    | "stream_options" => true
    _ => false
  }
}

///|
fn chat_message_json(message : ChatMessage) -> Json raise @runtime.SdkError {
  let fields : Map[String, Json] = {
    "role": message.role,
    "content": message.content,
  }
  match message.role {
    "system" | "user" | "assistant" =>
      if message.name is Some(name) {
        fields["name"] = name.to_json()
      }
    "tool" =>
      match message.name {
        Some(tool_call_id) => fields["tool_call_id"] = tool_call_id.to_json()
        None =>
          raise @runtime.Config(
            "tool chat message requires name as its tool_call_id",
          )
      }
    role => raise @runtime.Config("unsupported chat message role: " + role)
  }
  Json::object(fields)
}

///|
fn chat_parts(
  request : ChatRequest,
  stream : Bool,
) -> (@gen.CreateChatCompletionRequest, Json) raise @runtime.SdkError {
  for key, _ in request.extra {
    if is_chat_key(key) {
      raise @runtime.Config("extra parameter collides with known key: " + key)
    }
  }
  let fields : Map[String, Json] = {
    "model": request.model,
    "messages": Json::array(request.messages.map(chat_message_json)),
  }
  if request.max_tokens is Some(value) {
    fields["max_tokens"] = value.to_json()
  }
  if request.temperature is Some(value) {
    fields["temperature"] = value.to_json()
  }
  if stream {
    fields["stream"] = true.to_json()
    fields["stream_options"] = { "include_usage": true }
  }
  let raw = Json::object(fields)
  let generated : @gen.CreateChatCompletionRequest = @json.from_json(raw) catch {
    error =>
      raise @runtime.Config(
        "chat request does not match the generated schema: " + error.to_string(),
      )
  }
  let body = generated.to_json()
  guard body is Object(generated_fields) else {
    raise @runtime.Config("generated chat request must be an object")
  }
  for key, value in request.extra {
    generated_fields[key] = value
  }
  (generated, body)
}

///|
fn response_parts(
  request : ResponseRequest,
  stream : Bool,
) -> (@gen.CreateResponse, Json) raise @runtime.SdkError {
  for key, _ in request.extra {
    if is_response_key(key) {
      raise @runtime.Config("extra parameter collides with known key: " + key)
    }
  }
  let generated = @gen.CreateResponse::new(
    model=request.model,
    input=@gen.Text(request.input),
    temperature?=request.temperature,
    previous_response_id?=request.previous_response_id,
    max_output_tokens?=request.max_output_tokens,
    instructions?=request.instructions,
    stream?=if stream { Some(true) } else { None },
  )
  let body = generated.to_json()
  guard body is Object(fields) else {
    raise @runtime.Config("generated response request must be an object")
  }
  for key, value in request.extra {
    fields[key] = value
  }
  (generated, body)
}
