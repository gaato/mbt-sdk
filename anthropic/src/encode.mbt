///|
fn role_name(role : Role) -> String {
  match role {
    User => "user"
    Assistant => "assistant"
  }
}

///|
fn input_content_json(content : InputContent) -> Json {
  match content {
    Text(text) => text.to_json()
    Blocks(blocks) => Json::array(blocks.copy())
  }
}

///|
fn message_json(message : Message) -> Json {
  @sdkjson.ObjBuilder::new()
  .field("role", role_name(message.role))
  .field("content", input_content_json(message.content))
  .build()
}

///|
fn is_message_key(key : String) -> Bool {
  match key {
    "model"
    | "max_tokens"
    | "messages"
    | "system"
    | "temperature"
    | "stop_sequences"
    | "stream" => true
    _ => false
  }
}

///|
fn message_body(
  request : MessageRequest,
  stream : Bool,
) -> Json raise @runtime.SdkError {
  for key, _ in request.extra {
    if is_message_key(key) {
      raise @runtime.Config("extra parameter collides with known key: " + key)
    }
  }
  let builder = @sdkjson.ObjBuilder::new()
    .field("model", request.model)
    .field("max_tokens", request.max_tokens)
    .field("messages", request.messages.map(message_json))
    .opt("system", request.system)
    .opt("temperature", request.temperature)
    .opt("stop_sequences", request.stop_sequences)
  if stream {
    ignore(builder.field("stream", true))
  }
  for key, value in request.extra {
    ignore(builder.field(key, value))
  }
  builder.build()
}
