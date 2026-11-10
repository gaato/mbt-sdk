///|
fn decode_http_response(
  head : @http.ResponseHead,
  body : Bytes,
) -> MessageResponse raise DecodeError {
  decode_message_response(parse_json_body(body)) catch {
    error => raise decode_error(head, message=error.to_string(), body~)
  }
}

///|
async fn[T, M : @client.ResponseMode] Anthropic::send_with(
  self : Anthropic,
  request : @http.Request,
  reader : @client.ResponsePlan[Result[T, @client.ResponseFailure], M],
  bucket : String,
) -> Result[T, AnthropicFailure] {
  try {
    match
      @client.RequestPlan::new(request, reader)
      .attribute(@client.rate_limit_bucket, bucket)
      .send(self.client).body {
      Ok(value) => Ok(value)
      Err(error) => Err(Response(error))
    }
  } catch {
    DecodeError(error) => Err(Response(error))
    error => raise error
  }
}

///|
/// Creates and buffers one message.
pub async fn Anthropic::create_message(
  self : Anthropic,
  request : MessageRequest,
) -> Result[MessageResponse, AnthropicFailure] {
  try {
    let (params, body) = message_body(request, false)
    self.send_with(
      @gen.messages_post_request(params, anthropic_version=self.version).body_json(
        body,
      ),
      decode_reader((bytes, head) => decode_http_response(head, bytes)),
      "messages",
    )
  } catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
/// Creates a buffered message from generated parameters. `stream` is ignored.
pub async fn Anthropic::create_message_params(
  self : Anthropic,
  params : CreateMessageParams,
) -> Result[@gen.Message, AnthropicFailure] {
  try {
    let params = { ..params, stream: None, }
    self.send_with(
      @gen.messages_post_request(params, anthropic_version=self.version),
      decode_reader((bytes, head) => {
        take_decode(@gen.messages_post_decode(head, bytes))
      }),
      "messages",
    )
  } catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
fn decode_stream_data(
  head : @http.ResponseHead,
  data : String,
) -> MessageEvent raise DecodeError {
  let body = @utf8.encode(data)
  decode_message_event(parse_json_body(body)) catch {
    error => raise decode_error(head, message=error.to_string(), body~)
  }
}

///|
fn decode_stream_event(
  head : @http.ResponseHead,
  data : String,
) -> MessageStreamEvent raise DecodeError {
  let body = @utf8.encode(data)
  @json.from_json(parse_json_body(body)) catch {
    error => raise decode_error(head, message=error.to_string(), body~)
  }
}

///|
async fn Anthropic::each_stream_data(
  self : Anthropic,
  request : @http.Request,
  f : async (@http.ResponseHead, String) -> Unit,
) -> Result[Unit, AnthropicFailure] {
  self.send_with(
    request.header("accept", "text/event-stream"),
    @client.from_head(head => {
      @client.as_sse(
        // Compatible gateways add this sentinel; Anthropic streams still end at EOF.
        event => if event.data != "[DONE]" { f(head, event.data) },
      )
    }),
    "messages",
  )
}

///|
/// Dispatches message events in order, reading through EOF and closing on failure.
pub async fn Anthropic::stream_message(
  self : Anthropic,
  request : MessageRequest,
  f : async (MessageEvent) -> Unit,
) -> Result[Unit, AnthropicFailure] {
  try {
    let (params, body) = message_body(request, true)
    self.each_stream_data(
      @gen.messages_post_request(params, anthropic_version=self.version).body_json(
        body,
      ),
      (head, data) => f(decode_stream_data(head, data)),
    )
  } catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
/// Streams generated events. `stream` is forced on; future event kinds remain Unknown.
pub async fn Anthropic::stream_message_params(
  self : Anthropic,
  params : CreateMessageParams,
  f : async (MessageStreamEvent) -> Unit,
) -> Result[Unit, AnthropicFailure] {
  try {
    let params = { ..params, stream: Some(true), }
    self.each_stream_data(
      @gen.messages_post_request(params, anthropic_version=self.version),
      (head, data) => f(decode_stream_event(head, data)),
    )
  } catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
/// Counts input tokens without creating a message.
pub async fn Anthropic::count_tokens(
  self : Anthropic,
  request : MessageRequest,
) -> Result[Int32, AnthropicFailure] {
  try {
    let (params, body) = count_tokens_body(request)
    self.send_with(
      @gen.messages_count_tokens_post_request(
        params,
        anthropic_version=self.version,
      ).body_json(body),
      decode_reader((bytes, head) => {
        take_decode(@gen.messages_count_tokens_post_decode(head, bytes)).input_tokens
      }),
      "messages",
    )
  } catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
/// Lists a page of models. Follow `has_more` with `after_id=last_id`.
pub async fn Anthropic::list_models(
  self : Anthropic,
  limit? : Int32,
  after_id? : String,
  before_id? : String,
  lifecycle? : Array[ModelsListLifecycleItem],
) -> Result[ListResponseModelInfo, AnthropicFailure] {
  self.send_with(
    @gen.models_list_request(
      limit?,
      after_id?,
      before_id?,
      lifecycle?,
      anthropic_version=self.version,
    ),
    decode_reader((bytes, head) => {
      take_decode(@gen.models_list_decode(head, bytes))
    }),
    "models",
  ) catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
/// Iterates model pages following `has_more` and `last_id`.
pub fn Anthropic::paginate_models(
  self : Anthropic,
  limit? : Int32,
  lifecycle? : Array[ModelsListLifecycleItem],
) -> @client.Paginator[ModelInfo, AnthropicFailure] {
  @client.Paginator::with_cursor(cursor => {
    let page = match self.list_models(limit?, lifecycle?, after_id?=cursor) {
      Ok(page) => page
      Err(error) => return Err(error)
    }
    Ok(@client.Page::{
      items: page.data,
      next: if page.has_more {
        page.last_id
      } else {
        None
      },
    })
  })
}

///|
/// Retrieves one model by identifier or alias.
pub async fn Anthropic::retrieve_model(
  self : Anthropic,
  model_id : String,
) -> Result[ModelInfo, AnthropicFailure] {
  self.send_with(
    @gen.models_get_request(model_id, anthropic_version=self.version),
    decode_reader((bytes, head) => {
      take_decode(@gen.models_get_decode(head, bytes))
    }),
    "models",
  ) catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}
