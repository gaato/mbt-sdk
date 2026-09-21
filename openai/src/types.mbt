///|
/// The error body returned by the OpenAI API.
///
/// ```mbt check
/// test {
///   let error : @openai.ApiErrorBody = {
///     message: "invalid request",
///     type_: Some("invalid_request_error"),
///     param: None,
///     code: None,
///   }
///   assert_eq(error.message, "invalid request")
/// }
/// ```
pub(all) struct ApiErrorBody {
  message : String
  type_ : String?
  param : String?
  code : String?
} derive(Eq, Debug)

///|
/// Compares API error bodies field by field.
pub extend ApiErrorBody with Eq::{equal, not_equal}

///|
/// Debug representation of an API error body.
pub extend ApiErrorBody with @debug.Debug::{to_repr}

///|
/// Basic information about an OpenAI model.
pub(all) struct Model {
  id : String
  created : Int64?
  owned_by : String?
} derive(Eq, Debug)

///|
/// Compares model information field by field.
pub extend Model with Eq::{equal, not_equal}

///|
/// Debug representation of model information.
pub extend Model with @debug.Debug::{to_repr}

///|
/// Token usage reported by a response.
pub(all) struct Usage {
  input_tokens : Int
  output_tokens : Int
  total_tokens : Int
} derive(Eq, Debug)

///|
/// Compares response usage field by field.
pub extend Usage with Eq::{equal, not_equal}

///|
/// Debug representation of response usage.
pub extend Usage with @debug.Debug::{to_repr}

///|
/// Input accepted by the embeddings operation.
pub(all) struct EmbeddingRequest {
  model : String
  input : Array[String]
  dimensions : Int?
  user : String?
} derive(Eq, Debug)

///|
/// Compares embedding requests field by field.
pub extend EmbeddingRequest with Eq::{equal, not_equal}

///|
/// Debug representation of an embedding request.
pub extend EmbeddingRequest with @debug.Debug::{to_repr}

///|
/// Creates an embedding request and snapshots its input array.
///
/// ```mbt check
/// test {
///   let request = @openai.EmbeddingRequest::new(model="text-embedding-3-small", input=[
///     "hello",
///   ])
///   assert_eq(request.input, ["hello"])
/// }
/// ```
pub fn EmbeddingRequest::new(
  model~ : String,
  input~ : Array[String],
  dimensions? : Int,
  user? : String,
) -> EmbeddingRequest {
  { model, input: input.copy(), dimensions, user, }
}

///|
/// One embedding vector and its position in the result list.
pub(all) struct Embedding {
  index : Int
  embedding : Array[Double]
} derive(Eq, Debug)

///|
/// Compares embedding values field by field.
pub extend Embedding with Eq::{equal, not_equal}

///|
/// Debug representation of an embedding value.
pub extend Embedding with @debug.Debug::{to_repr}

///|
/// The flattened result of an embeddings operation.
pub(all) struct EmbeddingResponse {
  data : Array[Embedding]
  model : String
  prompt_tokens : Int
  total_tokens : Int
} derive(Eq, Debug)

///|
/// Compares embedding responses field by field.
pub extend EmbeddingResponse with Eq::{equal, not_equal}

///|
/// Debug representation of an embedding response.
pub extend EmbeddingResponse with @debug.Debug::{to_repr}

///|
/// A response lifecycle status. Unknown values are retained for forward compatibility.
pub(all) enum ResponseStatus {
  Completed
  Failed
  InProgress
  Incomplete
  Cancelled
  Queued
  Unknown(String)
} derive(Eq, Debug)

///|
/// Compares response statuses, including unknown raw values.
pub extend ResponseStatus with Eq::{equal, not_equal}

///|
/// Debug representation of a response status.
pub extend ResponseStatus with @debug.Debug::{to_repr}

///|
/// Input accepted by buffered and streaming response creation.
pub(all) struct ResponseRequest {
  model : String
  input : String
  instructions : String?
  max_output_tokens : Int?
  temperature : Double?
  previous_response_id : String?
  extra : Map[String, Json]
} derive(Eq, Debug)

///|
/// Compares response requests field by field.
pub extend ResponseRequest with Eq::{equal, not_equal}

///|
/// Debug representation of a response request.
pub extend ResponseRequest with @debug.Debug::{to_repr}

///|
/// Creates a response request and snapshots the extra parameter map.
///
/// ```mbt check
/// test {
///   let request = @openai.ResponseRequest::new(model="gpt-4.1", input="hello")
///   assert_eq(request.extra, {})
/// }
/// ```
pub fn ResponseRequest::new(
  model~ : String,
  input~ : String,
  instructions? : String,
  max_output_tokens? : Int,
  temperature? : Double,
  previous_response_id? : String,
  extra? : Map[String, Json],
) -> ResponseRequest {
  {
    model,
    input,
    instructions,
    max_output_tokens,
    temperature,
    previous_response_id,
    extra: extra.map(Map::copy).unwrap_or({}),
  }
}

///|
/// A decoded response together with its original JSON value.
pub(all) struct Response {
  id : String
  status : ResponseStatus
  model : String
  output_text : String
  usage : Usage?
  raw : Json
} derive(Eq, Debug)

///|
/// Compares decoded responses field by field.
pub extend Response with Eq::{equal, not_equal}

///|
/// Debug representation of a decoded response.
pub extend Response with @debug.Debug::{to_repr}

///|
/// One event from a streaming response. Unknown event types retain their raw JSON.
pub(all) enum ResponseEvent {
  Created(Response)
  InProgress(Response)
  OutputTextDelta(String)
  OutputTextDone(String)
  Completed(Response)
  Failed(Response)
  Incomplete(Response)
  Error(ApiErrorBody)
  Other(String, Json)
} derive(Eq, Debug)

///|
/// Compares response events, including retained unknown JSON.
pub extend ResponseEvent with Eq::{equal, not_equal}

///|
/// Debug representation of a response event.
pub extend ResponseEvent with @debug.Debug::{to_repr}
