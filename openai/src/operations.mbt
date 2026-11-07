///|
fn model_from_generated(model : @gen.Model) -> Model {
  { id: model.id, created: Some(model.created), owned_by: model.owned_by, }
}

///|
fn embedding_response_from_generated(
  response : @gen.CreateEmbeddingResponse,
) -> EmbeddingResponse {
  {
    data: response.data.map(item => {
      index: item.index,
      embedding: item.embedding,
    }),
    model: response.model,
    prompt_tokens: response.usage.prompt_tokens,
    total_tokens: response.usage.total_tokens,
  }
}

///|
async fn[T] OpenAI::send_with(
  self : OpenAI,
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
/// Creates and buffers one Chat Completions response.
pub async fn OpenAI::chat_completion(
  self : OpenAI,
  request : ChatRequest,
) -> ChatCompletion {
  let (generated, body) = chat_parts(request, false)
  self.send_with(
    @gen.create_chat_completion_request(generated).body_json(body),
    @client.as_bytes().map_with_head((bytes, head) => {
      decode_chat_completion(head, bytes)
    }),
    "chat",
  )
}

///|
fn decode_chat_stream_data(
  head : @model.ResponseHead,
  data : String,
) -> Array[ChatEvent] raise @client.ResponseError {
  let body = @utf8.encode(data)
  let raw = parse_json_body(body) catch {
    error =>
      raise @client.Deserialization(head, message=error.to_string(), body~)
  }
  decode_chat_chunk(raw) catch {
    error =>
      raise @client.Deserialization(head, message=error.to_string(), body~)
  }
}

///|
/// Dispatches Chat Completions events in wire order, including final usage.
/// EOF, [DONE], decoding failure and callback failure close the stream.
pub async fn OpenAI::stream_chat_completion(
  self : OpenAI,
  request : ChatRequest,
  f : async (ChatEvent) -> Unit,
) -> Unit {
  let (generated, body) = chat_parts(request, true)
  self.send_with(
    @gen.create_chat_completion_request(generated)
    .header("accept", "text/event-stream")
    .body_json(body),
    @client.from_head(head => {
      @client.as_sse(
        event => {
          for decoded in decode_chat_stream_data(head, event.data) {
            f(decoded)
          }
        },
        stop=event => event.data == "[DONE]",
      )
    }),
    "chat",
  )
}

///|
/// Lists the models visible to the configured account.
pub async fn OpenAI::list_models(self : OpenAI) -> Array[Model] {
  self.send_with(
    @gen.list_models_request(),
    @client.as_bytes().map_with_head((bytes, head) => {
      @gen.list_models_decode(head, bytes).data.map(model_from_generated)
    }),
    "models",
  )
}

///|
/// Retrieves one model by identifier.
pub async fn OpenAI::retrieve_model(self : OpenAI, model : String) -> Model {
  self.send_with(
    @gen.retrieve_model_request(model),
    @client.as_bytes().map_with_head((bytes, head) => {
      model_from_generated(@gen.retrieve_model_decode(head, bytes))
    }),
    "models",
  )
}

///|
/// Creates embeddings for every input string in the request.
pub async fn OpenAI::create_embeddings(
  self : OpenAI,
  request : EmbeddingRequest,
) -> EmbeddingResponse {
  let body = @gen.CreateEmbeddingRequest::new(
    model=request.model,
    input=@gen.TextArray(request.input.copy()),
    dimensions?=request.dimensions,
    user?=request.user,
  )
  self.send_with(
    @gen.create_embedding_request(body),
    @client.as_bytes().map_with_head((bytes, head) => {
      embedding_response_from_generated(
        @gen.create_embedding_decode(head, bytes),
      )
    }),
    "embeddings",
  )
}

///|
/// Creates and buffers one model response.
pub async fn OpenAI::create_response(
  self : OpenAI,
  request : ResponseRequest,
) -> Response {
  let (generated, body) = response_parts(request, false)
  self.send_with(
    @gen.create_response_request(generated).body_json(body),
    @client.as_bytes().map_with_head((bytes, head) => {
      decode_response(head, bytes)
    }),
    "responses",
  )
}

///|
fn decode_stream_data(
  head : @model.ResponseHead,
  data : String,
) -> ResponseEvent raise @client.ResponseError {
  let body = @utf8.encode(data)
  decode_response_event(parse_json_body(body)) catch {
    error =>
      raise @client.Deserialization(head, message=error.to_string(), body~)
  }
}

///|
/// Dispatches Responses events in wire order, closing on EOF, [DONE] or failure.
/// User callback failures happen outside the retry attempt.
pub async fn OpenAI::stream_response(
  self : OpenAI,
  request : ResponseRequest,
  f : async (ResponseEvent) -> Unit,
) -> Unit {
  let (generated, body) = response_parts(request, true)
  self.send_with(
    @gen.create_response_request(generated)
    .header("accept", "text/event-stream")
    .body_json(body),
    @client.from_head(head => {
      @client.as_sse(event => f(decode_stream_data(head, event.data)), stop=event => {
        event.data == "[DONE]"
      })
    }),
    "responses",
  )
}
