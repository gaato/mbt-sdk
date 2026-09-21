///|
priv struct UsageJson(Usage)

///|
impl @json.FromJson for UsageJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  UsageJson({
    input_tokens: @sdkjson.field(obj, "input_tokens", path),
    output_tokens: @sdkjson.field(obj, "output_tokens", path),
    total_tokens: @sdkjson.field(obj, "total_tokens", path),
  })
}

///|
fn response_status(
  value : Json,
  path : @json.JsonPath,
) -> ResponseStatus raise @json.JsonDecodeError {
  @sdkjson.open_string(
    value,
    path,
    raw => {
      match raw {
        "completed" => Some(Completed)
        "failed" => Some(Failed)
        "in_progress" => Some(InProgress)
        "incomplete" => Some(Incomplete)
        "cancelled" => Some(Cancelled)
        "queued" => Some(Queued)
        _ => None
      }
    },
    raw => Unknown(raw),
  )
}

///|
fn output_text(
  output : Array[Json],
  path : @json.JsonPath,
) -> String raise @json.JsonDecodeError {
  let result = StringBuilder()
  for index, item in output {
    let item_path = path.add_index(index)
    let obj = @sdkjson.expect_object(item, item_path)
    let kind : String = @sdkjson.field(obj, "type", item_path)
    if kind == "message" {
      let content : Array[Json] = @sdkjson.field(obj, "content", item_path)
      for content_index, part in content {
        let part_path = item_path.add_key("content").add_index(content_index)
        let part_obj = @sdkjson.expect_object(part, part_path)
        let part_kind : String = @sdkjson.field(part_obj, "type", part_path)
        if part_kind == "output_text" {
          let text : String = @sdkjson.field(part_obj, "text", part_path)
          result.write_string(text)
        }
      }
    }
  }
  result.to_string()
}

///|
priv struct ResponseJson(Response)

///|
impl @json.FromJson for ResponseJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let raw_status : Json = @sdkjson.field(obj, "status", path)
  let output : Array[Json] = @sdkjson.field(obj, "output", path)
  let usage : UsageJson? = @sdkjson.opt_field(obj, "usage", path)
  ResponseJson({
    id: @sdkjson.field(obj, "id", path),
    status: response_status(raw_status, path.add_key("status")),
    model: @sdkjson.field(obj, "model", path),
    output_text: output_text(output, path.add_key("output")),
    usage: usage.map(value => value.0),
    raw: value,
  })
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
fn decode_response(value : Json) -> Response raise @json.JsonDecodeError {
  let decoded : ResponseJson = @json.from_json(value)
  decoded.0
}

///|
fn stream_error(
  obj : Map[String, Json],
  path : @json.JsonPath,
) -> ApiErrorBody raise @json.JsonDecodeError {
  {
    message: @sdkjson.field(obj, "message", path),
    type_: None,
    param: @sdkjson.opt_field(obj, "param", path),
    code: @sdkjson.opt_field(obj, "code", path),
  }
}

///|
priv struct ResponseEventJson(ResponseEvent)

///|
impl @json.FromJson for ResponseEventJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let kind : String = @sdkjson.field(obj, "type", path)
  let event = match kind {
    "response.created" => {
      let response : ResponseJson = @sdkjson.field(obj, "response", path)
      Created(response.0)
    }
    "response.in_progress" => {
      let response : ResponseJson = @sdkjson.field(obj, "response", path)
      InProgress(response.0)
    }
    "response.output_text.delta" =>
      OutputTextDelta(@sdkjson.field(obj, "delta", path))
    "response.output_text.done" =>
      OutputTextDone(@sdkjson.field(obj, "text", path))
    "response.completed" => {
      let response : ResponseJson = @sdkjson.field(obj, "response", path)
      Completed(response.0)
    }
    "response.failed" => {
      let response : ResponseJson = @sdkjson.field(obj, "response", path)
      Failed(response.0)
    }
    "response.incomplete" => {
      let response : ResponseJson = @sdkjson.field(obj, "response", path)
      Incomplete(response.0)
    }
    "error" => Error(stream_error(obj, path))
    _ => Other(kind, value)
  }
  ResponseEventJson(event)
}

///|
fn decode_response_event(
  value : Json,
) -> ResponseEvent raise @json.JsonDecodeError {
  let decoded : ResponseEventJson = @json.from_json(value)
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
