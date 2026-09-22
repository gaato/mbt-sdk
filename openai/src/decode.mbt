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
