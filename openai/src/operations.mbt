///|
fn model_from_generated(model : @gen.Model) -> Model {
  { id: model.id, created: model.created, owned_by: model.owned_by, }
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
    prompt_tokens: response.usage.bind(usage => usage.prompt_tokens),
    total_tokens: response.usage.map(usage => usage.total_tokens),
  }
}

///|
async fn[T, M : @client.ResponseMode] OpenAI::send_with(
  self : OpenAI,
  request : @http.Request,
  reader : @client.ResponsePlan[Result[T, @client.ResponseFailure], M],
  bucket : String,
) -> Result[T, OpenAIFailure] {
  if self.bearer_error is Some(message) {
    return Err(Validation(message))
  }
  try {
    request.headers.validate()
    @http.Headers::of(
      self.default_headers
      .iter()
      .filter(pair => !request.headers.contains(pair.0))
      .collect(),
    ).validate()
  } catch {
    @http.TransportError(detail~, ..) => return Err(Validation(detail))
  }
  // The runtime merges its Authorization default after the plan is built.
  let request = request.attribute(
    @http.credential_headers,
    [
      ..request.attributes.get(@http.credential_headers).unwrap_or([]),
      "authorization",
    ],
  )
  try {
    match
      @client.RequestPlan::new(request, reader)
      .attribute(@client.rate_limit_bucket, bucket)
      .send(self.client, decide_retry=compatible_retry).body {
      Ok(value) => Ok(value)
      Err(error) => {
        // Classify the final status after the HTTP client has applied retries.
        if error is @client.UnexpectedStatus(head, body~) {
          check_api_error(head, body, unexpected_status=true)
        }
        Err(Response(error))
      }
    }
  } catch {
    DecodeError(error) => Err(Response(error))
    ApiError(head, error, body~) => Err(Api(head, error, body~))
    error => raise error
  }
}

///|
/// Creates and buffers one Chat Completions response.
pub async fn OpenAI::chat_completion(
  self : OpenAI,
  request : ChatRequest,
) -> Result[ChatCompletion, OpenAIFailure] {
  try {
    let (generated, body) = chat_parts(request, false)
    self.send_with(
      @gen.create_chat_completion_request(generated).body_json(body),
      decode_reader((bytes, head) => decode_chat_completion(head, bytes)),
      "chat",
    )
  } catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
fn decode_chat_stream_data(
  head : @http.ResponseHead,
  data : String,
) -> Array[ChatEvent] raise {
  let body = @utf8.encode(data)
  check_api_error(head, body)
  let raw = parse_json_body(body) catch {
    error => raise decode_error(head, message=error.to_string(), body~)
  }
  decode_chat_chunk(raw) catch {
    error => raise decode_error(head, message=error.to_string(), body~)
  }
}

///|
/// Dispatches Chat Completions events in wire order, including final usage.
/// EOF, [DONE], decoding failure and callback failure close the stream.
pub async fn OpenAI::stream_chat_completion(
  self : OpenAI,
  request : ChatRequest,
  f : async (ChatEvent) -> Unit,
) -> Result[Unit, OpenAIFailure] {
  try {
    let (generated, body) = chat_parts(request, true)
    self.send_with(
      @gen.create_chat_completion_request(generated)
      .header("accept", "text/event-stream")
      .body_json(body),
      @client.from_head(head => {
        @client.as_sse(
          event => {
            check_named_error(head, event.event, event.data)
            for decoded in decode_chat_stream_data(head, event.data) {
              f(decoded)
            }
          },
          stop=event => event.data == "[DONE]",
        )
      }),
      "chat",
    )
  } catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
/// Lists the models visible to the configured account.
pub async fn OpenAI::list_models(
  self : OpenAI,
) -> Result[Array[Model], OpenAIFailure] {
  self.send_with(
    @gen.list_models_request(),
    decode_reader((bytes, head) => {
      take_decode(@gen.list_models_decode(head, bytes)).data.map(
        model_from_generated,
      )
    }),
    "models",
  ) catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
/// Retrieves one model by identifier.
pub async fn OpenAI::retrieve_model(
  self : OpenAI,
  model : String,
) -> Result[Model, OpenAIFailure] {
  self.send_with(
    @gen.retrieve_model_request(model),
    decode_reader((bytes, head) => {
      model_from_generated(take_decode(@gen.retrieve_model_decode(head, bytes)))
    }),
    "models",
  ) catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
/// Creates embeddings for every input string in the request.
pub async fn OpenAI::create_embeddings(
  self : OpenAI,
  request : EmbeddingRequest,
) -> Result[EmbeddingResponse, OpenAIFailure] {
  self.send_with(
    embedding_http_request(request),
    decode_reader((bytes, head) => {
      embedding_response_from_generated(
        take_decode(@gen.create_embedding_decode(head, bytes)),
      )
    }),
    "embeddings",
  ) catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}

///|
/// Creates and buffers one model response.
pub async fn OpenAI::create_response(
  self : OpenAI,
  request : ResponseRequest,
) -> Result[Response, OpenAIFailure] {
  try {
    let (generated, body) = response_parts(request, false)
    self.send_with(
      @gen.create_response_request(generated).body_json(body),
      decode_reader((bytes, head) => decode_response(head, bytes)),
      "responses",
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
) -> ResponseEvent raise {
  let body = @utf8.encode(data)
  check_api_error(head, body)
  let raw = parse_json_body(body) catch {
    error => raise decode_error(head, message=error.to_string(), body~)
  }
  decode_response_event(raw) catch {
    error => raise decode_error(head, message=error.to_string(), body~)
  }
}

///|
/// Dispatches Responses events in wire order, closing on EOF, [DONE] or failure.
/// A typed error in an ordinary data frame reaches the callback as `Error`.
/// The stream can still return `Ok(())` at EOF after delivering this event.
/// User callback failures happen outside the retry attempt.
pub async fn OpenAI::stream_response(
  self : OpenAI,
  request : ResponseRequest,
  f : async (ResponseEvent) -> Unit,
) -> Result[Unit, OpenAIFailure] {
  try {
    let (generated, body) = response_parts(request, true)
    self.send_with(
      @gen.create_response_request(generated)
      .header("accept", "text/event-stream")
      .body_json(body),
      @client.from_head(head => {
        @client.as_sse(
          event => {
            check_named_error(head, event.event, event.data)
            f(decode_stream_data(head, event.data))
          },
          stop=event => event.data == "[DONE]",
        )
      }),
      "responses",
    )
  } catch {
    ValidationError(message~) => Err(Validation(message))
    error => raise error
  }
}
