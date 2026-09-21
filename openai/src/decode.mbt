///|
priv struct ModelJson(Model)

///|
impl @json.FromJson for ModelJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let created : Json? = @sdkjson.opt_field(obj, "created", path)
  ModelJson({
    id: @sdkjson.field(obj, "id", path),
    created: created.map(raw => json_int64(raw, path.add_key("created"))),
    owned_by: @sdkjson.opt_field(obj, "owned_by", path),
  })
}

///|
priv struct ModelListJson(Array[Model])

///|
impl @json.FromJson for ModelListJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let values : Array[ModelJson] = @sdkjson.field(obj, "data", path)
  ModelListJson(values.map(value => value.0))
}

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
priv struct EmbeddingJson(Embedding)

///|
impl @json.FromJson for EmbeddingJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  EmbeddingJson({
    index: @sdkjson.field(obj, "index", path),
    embedding: @sdkjson.field(obj, "embedding", path),
  })
}

///|
priv struct EmbeddingResponseJson(EmbeddingResponse)

///|
impl @json.FromJson for EmbeddingResponseJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let data : Array[EmbeddingJson] = @sdkjson.field(obj, "data", path)
  let usage : Json = @sdkjson.field(obj, "usage", path)
  let usage_obj = @sdkjson.expect_object(usage, path.add_key("usage"))
  EmbeddingResponseJson({
    data: data.map(value => value.0),
    model: @sdkjson.field(obj, "model", path),
    prompt_tokens: @sdkjson.field(
      usage_obj,
      "prompt_tokens",
      path.add_key("usage"),
    ),
    total_tokens: @sdkjson.field(
      usage_obj,
      "total_tokens",
      path.add_key("usage"),
    ),
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
fn decode_model(value : Json) -> Model raise @json.JsonDecodeError {
  let decoded : ModelJson = @json.from_json(value)
  decoded.0
}

///|
fn decode_model_list(value : Json) -> Array[Model] raise @json.JsonDecodeError {
  let decoded : ModelListJson = @json.from_json(value)
  decoded.0
}

///|
fn decode_embedding_response(
  value : Json,
) -> EmbeddingResponse raise @json.JsonDecodeError {
  let decoded : EmbeddingResponseJson = @json.from_json(value)
  decoded.0
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
fn parse_plain_int64(text : String) -> Int64? {
  if text.length() == 0 {
    return None
  }
  let negative = text[0] == '-'
  let digits_start = if negative { 1 } else { 0 }
  if digits_start == text.length() {
    return None
  }
  for index in digits_start..<text.length() {
    if text[index] < '0' || text[index] > '9' {
      return None
    }
  }
  let mut significant_start = digits_start
  while significant_start < text.length() && text[significant_start] == '0' {
    significant_start += 1
  }
  if significant_start == text.length() {
    return Some(0L)
  }
  let significant_length = text.length() - significant_start
  let limit = if negative {
    "9223372036854775808"
  } else {
    "9223372036854775807"
  }
  if significant_length > limit.length() {
    return None
  }
  if significant_length == limit.length() {
    for offset in 0..<significant_length {
      let digit = text[significant_start + offset]
      let boundary = limit[offset]
      if digit > boundary {
        return None
      }
      if digit < boundary {
        break
      }
    }
  }
  let mut result = 0L
  for index in significant_start..<text.length() {
    let digit = (text[index] - '0').to_int().to_int64()
    if negative {
      result = result * 10L - digit
    } else {
      result = result * 10L + digit
    }
  }
  Some(result)
}

///|
fn is_plain_integer(text : String) -> Bool {
  if text.length() == 0 {
    return false
  }
  let start = if text[0] == '-' { 1 } else { 0 }
  if start == text.length() {
    return false
  }
  for index in start..<text.length() {
    if text[index] < '0' || text[index] > '9' {
      return false
    }
  }
  true
}

///|
fn json_int64(
  value : Json,
  path : @json.JsonPath,
) -> Int64 raise @json.JsonDecodeError {
  guard value is Number(raw, repr~) else {
    raise @json.JsonDecodeError((path, "expected JSON number for Int64"))
  }
  if repr is Some(text) && is_plain_integer(text) {
    match parse_plain_int64(text) {
      Some(value) => return value
      None =>
        raise @json.JsonDecodeError(
          (path, "JSON number is outside Int64 range"),
        )
    }
  }
  if raw.is_nan() ||
    raw < -9223372036854775808.0 ||
    raw >= 9223372036854775808.0 {
    raise @json.JsonDecodeError((path, "JSON number is outside Int64 range"))
  }
  let result = raw.to_int64()
  if result.to_double() != raw {
    raise @json.JsonDecodeError((path, "expected integral JSON number"))
  }
  result
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
