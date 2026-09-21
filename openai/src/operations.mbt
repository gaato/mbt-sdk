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
/// Lists the models visible to the configured account.
pub async fn OpenAI::list_models(
  self : OpenAI,
) -> Array[Model] raise @runtime.SdkError {
  let response = self.client.send(
    @http.Request::get("/models"),
    bucket="models",
  )
  decode_http_response(response, decode_model_list)
}

///|
/// Retrieves one model by identifier.
pub async fn OpenAI::retrieve_model(
  self : OpenAI,
  model : String,
) -> Model raise @runtime.SdkError {
  let response = self.client.send(
    @http.Request::get("/models/" + model),
    bucket="models",
  )
  decode_http_response(response, decode_model)
}

///|
/// Creates embeddings for every input string in the request.
pub async fn OpenAI::create_embeddings(
  self : OpenAI,
  request : EmbeddingRequest,
) -> EmbeddingResponse raise @runtime.SdkError {
  let response = self.client.send(
    @http.Request::post("/embeddings").json_body(embedding_body(request)),
    bucket="embeddings",
  )
  decode_http_response(response, decode_embedding_response)
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
