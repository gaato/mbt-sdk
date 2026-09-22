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
/// Lists the models visible to the configured account.
pub async fn OpenAI::list_models(
  self : OpenAI,
) -> Array[Model] raise @runtime.SdkError {
  let response = self.client.send(@gen.list_models_request(), bucket="models")
  @gen.list_models_decode(response).data.map(model_from_generated)
}

///|
/// Retrieves one model by identifier.
pub async fn OpenAI::retrieve_model(
  self : OpenAI,
  model : String,
) -> Model raise @runtime.SdkError {
  let response = self.client.send(
    @gen.retrieve_model_request(model),
    bucket="models",
  )
  model_from_generated(@gen.retrieve_model_decode(response))
}

///|
/// Creates embeddings for every input string in the request.
pub async fn OpenAI::create_embeddings(
  self : OpenAI,
  request : EmbeddingRequest,
) -> EmbeddingResponse raise @runtime.SdkError {
  let body = @gen.CreateEmbeddingRequest::new(
    model=request.model,
    input=@gen.TextArray(request.input.copy()),
    dimensions?=request.dimensions,
    user?=request.user,
  )
  let response = self.client.send(
    @gen.create_embedding_request(body),
    bucket="embeddings",
  )
  embedding_response_from_generated(@gen.create_embedding_decode(response))
}

///|
/// Creates and buffers one model response.
pub async fn OpenAI::create_response(
  self : OpenAI,
  request : ResponseRequest,
) -> Response raise @runtime.SdkError {
  let (generated, body) = response_parts(request, false)
  let response = self.client.send(
    @gen.create_response_request(generated).json_body(body),
    bucket="responses",
  )
  decode_response(response)
}

///|
priv suberror StreamDone {
  StreamDone
}

///|
fn decode_stream_data(data : String) -> ResponseEvent raise @runtime.SdkError {
  let body = @utf8.encode(data)
  decode_response_event(parse_json_body(body)) catch {
    error => raise @runtime.Decode(message=error.to_string(), body~)
  }
}

///|
/// Creates a streaming response and dispatches decoded events in arrival order.
/// The stream is closed after EOF, `[DONE]`, decoding failure, or callback failure.
pub async fn[E : Error] OpenAI::stream_response(
  self : OpenAI,
  request : ResponseRequest,
  f : async (ResponseEvent) -> Unit raise E,
) -> Unit {
  let (generated, body) = response_parts(request, true)
  let (_, stream) = self.client.send_stream(
    @gen.create_response_request(generated)
    .header("accept", "text/event-stream")
    .json_body(body),
    bucket="responses",
  )
  @sse.each_event(stream, event => {
    if event.data == "[DONE]" {
      raise StreamDone
    }
    f(decode_stream_data(event.data))
  }) catch {
    StreamDone => ()
    error => raise error
  }
}
