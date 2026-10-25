///|
fn decode_http_response(
  head : @model.ResponseHead,
  body : Bytes,
) -> MessageResponse raise @client.ResponseError {
  decode_message_response(parse_json_body(body)) catch {
    error =>
      raise @client.Deserialization(head, message=error.to_string(), body~)
  }
}

///|
async fn[T] Anthropic::send_with(
  self : Anthropic,
  request : @model.Request,
  reader : @client.ResponseAs[T],
  bucket : String,
) -> T {
  self.client.send(
    @client.ClientRequest::new(request, reader).attribute(
      @client.rate_limit_bucket, bucket,
    ),
  ).body
}

///|
/// Creates and buffers one message.
pub async fn Anthropic::create_message(
  self : Anthropic,
  request : MessageRequest,
) -> MessageResponse {
  let (params, body) = message_body(request, false)
  self.send_with(
    @gen.messages_post_request(params, anthropic_version=self.version).body_json(
      body,
    ),
    @client.as_bytes().map_with_head((bytes, head) => {
      decode_http_response(head, bytes)
    }),
    "messages",
  )
}

///|
/// Creates a buffered message from generated parameters. `stream` is ignored.
pub async fn Anthropic::create_message_params(
  self : Anthropic,
  params : CreateMessageParams,
) -> @gen.Message {
  let params = { ..params, stream: None, }
  self.send_with(
    @gen.messages_post_request(params, anthropic_version=self.version),
    @client.as_bytes().map_with_head((bytes, head) => {
      @gen.messages_post_decode(head, bytes)
    }),
    "messages",
  )
}

///|
fn decode_stream_data(
  head : @model.ResponseHead,
  data : String,
) -> MessageEvent raise @client.ResponseError {
  let body = @utf8.encode(data)
  decode_message_event(parse_json_body(body)) catch {
    error =>
      raise @client.Deserialization(head, message=error.to_string(), body~)
  }
}

///|
fn decode_stream_event(
  head : @model.ResponseHead,
  data : String,
) -> MessageStreamEvent raise @client.ResponseError {
  let body = @utf8.encode(data)
  @json.from_json(parse_json_body(body)) catch {
    error =>
      raise @client.Deserialization(head, message=error.to_string(), body~)
  }
}

///|
async fn Anthropic::each_stream_data(
  self : Anthropic,
  request : @model.Request,
  f : async (@model.ResponseHead, String) -> Unit,
) -> Unit {
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
) -> Unit {
  let (params, body) = message_body(request, true)
  self.each_stream_data(
    @gen.messages_post_request(params, anthropic_version=self.version).body_json(
      body,
    ),
    (head, data) => f(decode_stream_data(head, data)),
  )
}

///|
/// Streams generated events. `stream` is forced on; future event kinds remain Unknown.
pub async fn Anthropic::stream_message_params(
  self : Anthropic,
  params : CreateMessageParams,
  f : async (MessageStreamEvent) -> Unit,
) -> Unit {
  let params = { ..params, stream: Some(true), }
  self.each_stream_data(
    @gen.messages_post_request(params, anthropic_version=self.version),
    (head, data) => f(decode_stream_event(head, data)),
  )
}

///|
/// Counts input tokens without creating a message.
pub async fn Anthropic::count_tokens(
  self : Anthropic,
  request : MessageRequest,
) -> Int32 {
  let (params, body) = count_tokens_body(request)
  self.send_with(
    @gen.messages_count_tokens_post_request(
      params,
      anthropic_version=self.version,
    ).body_json(body),
    @client.as_bytes().map_with_head((bytes, head) => {
      @gen.messages_count_tokens_post_decode(head, bytes).input_tokens
    }),
    "messages",
  )
}

///|
/// Lists a page of models. Follow `has_more` with `after_id=last_id`.
pub async fn Anthropic::list_models(
  self : Anthropic,
  limit? : Int32,
  after_id? : String,
  before_id? : String,
  lifecycle? : Array[ModelsListLifecycleItem],
) -> ListResponseModelInfo {
  self.send_with(
    @gen.models_list_request(
      limit?,
      after_id?,
      before_id?,
      lifecycle?,
      anthropic_version=self.version,
    ),
    @client.as_bytes().map_with_head((bytes, head) => {
      @gen.models_list_decode(head, bytes)
    }),
    "models",
  )
}

///|
/// Iterates model pages following `has_more` and `last_id`.
pub fn Anthropic::paginate_models(
  self : Anthropic,
  limit? : Int32,
  lifecycle? : Array[ModelsListLifecycleItem],
) -> @client.Paginator[ModelInfo, Error] {
  @client.Paginator::with_cursor(cursor => {
    let page = self.list_models(limit?, lifecycle?, after_id?=cursor)
    @client.Page::{
      items: page.data,
      next: if page.has_more {
        page.last_id
      } else {
        None
      },
    }
  })
}

///|
/// Retrieves one model by identifier or alias.
pub async fn Anthropic::retrieve_model(
  self : Anthropic,
  model_id : String,
) -> ModelInfo {
  self.send_with(
    @gen.models_get_request(model_id, anthropic_version=self.version),
    @client.as_bytes().map_with_head((bytes, head) => {
      @gen.models_get_decode(head, bytes)
    }),
    "models",
  )
}
