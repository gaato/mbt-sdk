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
