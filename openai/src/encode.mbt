///|
fn embedding_body(request : EmbeddingRequest) -> Json {
  @sdkjson.ObjBuilder::new()
  .field("model", request.model)
  .field("input", request.input)
  .opt("dimensions", request.dimensions)
  .opt("user", request.user)
  .build()
}

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
fn response_body(
  request : ResponseRequest,
  stream : Bool,
) -> Json raise @runtime.SdkError {
  for key, _ in request.extra {
    if is_response_key(key) {
      raise @runtime.Config("extra parameter collides with known key: " + key)
    }
  }
  let builder = @sdkjson.ObjBuilder::new()
    .field("model", request.model)
    .field("input", request.input)
    .opt("instructions", request.instructions)
    .opt("max_output_tokens", request.max_output_tokens)
    .opt("temperature", request.temperature)
    .opt("previous_response_id", request.previous_response_id)
  if stream {
    ignore(builder.field("stream", true))
  }
  for key, value in request.extra {
    ignore(builder.field(key, value))
  }
  builder.build()
}
