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
/// One text message sent to the Chat Completions API.
///
/// ```mbt check
/// test {
///   let message = @openai.ChatMessage::user("hello")
///   assert_eq(message.role, "user")
///   assert_eq(message.content, "hello")
/// }
/// ```
pub(all) struct ChatMessage {
  role : String
  content : String
  name : String?
} derive(Eq, Debug)

///|
/// Compares chat messages field by field.
pub extend ChatMessage with Eq::{equal, not_equal}

///|
/// Debug representation of a chat message.
pub extend ChatMessage with @debug.Debug::{to_repr}

///|
/// Creates a system chat message.
///
/// ```mbt check
/// test {
///   assert_eq(@openai.ChatMessage::system("Be concise").role, "system")
/// }
/// ```
pub fn ChatMessage::system(content : String) -> ChatMessage {
  { role: "system", content, name: None, }
}

///|
/// Creates a user chat message.
///
/// ```mbt check
/// test {
///   assert_eq(@openai.ChatMessage::user("hello").role, "user")
/// }
/// ```
pub fn ChatMessage::user(content : String) -> ChatMessage {
  { role: "user", content, name: None, }
}

///|
/// Creates an assistant chat message.
///
/// ```mbt check
/// test {
///   assert_eq(@openai.ChatMessage::assistant("hello").role, "assistant")
/// }
/// ```
pub fn ChatMessage::assistant(content : String) -> ChatMessage {
  { role: "assistant", content, name: None, }
}

///|
/// Input accepted by buffered and streaming Chat Completions operations.
pub(all) struct ChatRequest {
  model : String
  messages : Array[ChatMessage]
  max_tokens : Int?
  temperature : Double?
  extra : Map[String, Json]
} derive(Eq, Debug)

///|
/// Compares chat requests field by field.
pub extend ChatRequest with Eq::{equal, not_equal}

///|
/// Debug representation of a chat request.
pub extend ChatRequest with @debug.Debug::{to_repr}

///|
/// Creates a chat request and snapshots mutable inputs.
///
/// ```mbt check
/// test {
///   let request = @openai.ChatRequest::new(model="gpt-4o-mini", messages=[
///     @openai.ChatMessage::user("hello"),
///   ])
///   assert_eq(request.messages.length(), 1)
/// }
/// ```
pub fn ChatRequest::new(
  model~ : String,
  messages~ : Array[ChatMessage],
  max_tokens? : Int,
  temperature? : Double,
  extra? : Map[String, Json],
) -> ChatRequest {
  {
    model,
    messages: messages.copy(),
    max_tokens,
    temperature,
    extra: extra.map(Map::copy).unwrap_or({}),
  }
}

///|
/// Why a chat completion stopped. Unknown values are retained.
pub(all) enum FinishReason {
  Stop
  Length
  ToolCalls
  ContentFilter
  Unknown(String)
} derive(Eq, Debug)

///|
/// Compares finish reasons, including unknown raw values.
pub extend FinishReason with Eq::{equal, not_equal}

///|
/// Debug representation of a finish reason.
pub extend FinishReason with @debug.Debug::{to_repr}

///|
/// A buffered chat completion together with its original JSON value.
pub(all) struct ChatCompletion {
  id : String
  model : String
  text : String
  finish_reason : FinishReason?
  usage : Usage?
  raw : Json
} derive(Eq, Debug)

///|
/// Compares chat completions field by field.
pub extend ChatCompletion with Eq::{equal, not_equal}

///|
/// Debug representation of a chat completion.
pub extend ChatCompletion with @debug.Debug::{to_repr}

///|
/// One event from a streaming chat completion. Unknown chunks retain raw JSON.
pub(all) enum ChatEvent {
  Delta(String)
  ReasoningDelta(String)
  Finished(FinishReason)
  Usage(Usage)
  Other(String, Json)
} derive(Eq, Debug)

///|
/// Compares chat events, including retained unknown JSON.
pub extend ChatEvent with Eq::{equal, not_equal}

///|
/// Debug representation of a chat event.
pub extend ChatEvent with @debug.Debug::{to_repr}

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
