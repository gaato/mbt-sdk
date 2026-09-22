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
  let generated : @gen.CreateResponse = {
    metadata: @sdkjson.Absent,
    temperature: @sdkjson.Presence::from_option(request.temperature),
    top_p: @sdkjson.Absent,
    user: None,
    service_tier: @sdkjson.Absent,
    previous_response_id: @sdkjson.Presence::from_option(
      request.previous_response_id,
    ),
    model: request.model,
    reasoning: @sdkjson.Absent,
    max_output_tokens: @sdkjson.Presence::from_option(request.max_output_tokens),
    instructions: @sdkjson.Presence::from_option(request.instructions),
    text: None,
    tools: None,
    tool_choice: None,
    truncation: @sdkjson.Absent,
    input: @gen.Text(request.input),
    include_: @sdkjson.Absent,
    parallel_tool_calls: @sdkjson.Absent,
    store: @sdkjson.Absent,
    stream: if stream {
      @sdkjson.Value(true)
    } else {
      @sdkjson.Absent
    },
  }
  let body = generated.to_json()
  guard body is Object(fields) else {
    raise @runtime.Config("generated response request must be an object")
  }
  for key, value in request.extra {
    fields[key] = value
  }
  (generated, body)
}
