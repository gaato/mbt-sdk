///|
fn[T] decode_http_response(
  response : @http.Response,
  decode : (Json) -> T raise @json.JsonDecodeError,
) -> T raise @runtime.SdkError {
  decode(parse_json_body(response.body)) catch {
    error =>
      raise @runtime.Decode(message=error.to_string(), body=response.body)
  }
}

///|
fn model_from_generated(model : @gen.Model) -> Model {
  {
    id: model.id,
    created: Some(model.created),
    owned_by: Some(model.owned_by),
  }
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
  let body : @gen.CreateEmbeddingRequest = {
    model: request.model,
    input: @gen.TextArray(request.input.copy()),
    encoding_format: None,
    dimensions: request.dimensions,
    user: request.user,
  }
  let generated_request = @gen.create_embedding_request(body)
  let response = self.client.send(
    generated_request.json_body(embedding_body(request)),
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
  let body = response_body(request, false)
  let response = self.client.send(
    @http.Request::post("/responses").json_body(body),
    bucket="responses",
  )
  decode_http_response(response, decode_response)
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
  let body = response_body(request, true)
  let (_, stream) = self.client.send_stream(
    @http.Request::post("/responses")
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
