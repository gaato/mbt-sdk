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
/// A function tool definition shared by Chat Completions and Responses.
///
/// ```mbt check
/// test {
///   let tool = @openai.ToolDef::new(name="lookup", parameters={ "type": "object" })
///   assert_eq(tool.name, "lookup")
/// }
/// ```
pub(all) struct ToolDef {
  name : String
  description : String?
  parameters : Json
  strict : Bool?
} derive(Eq, Debug)

///|
/// Compares tool definitions field by field.
pub extend ToolDef with Eq::{equal, not_equal}

///|
/// Debug representation of a tool definition.
pub extend ToolDef with @debug.Debug::{to_repr}

///|
/// Creates a function tool definition with a JSON Schema parameter object.
pub fn ToolDef::new(
  name~ : String,
  parameters~ : Json,
  description? : String,
  strict? : Bool,
) -> ToolDef {
  { name, description, parameters, strict, }
}

///|
/// A function call produced by a model. Arguments remain raw text until parsed.
pub(all) struct ToolCall {
  id : String
  name : String
  arguments : String
} derive(Eq, Debug)

///|
/// Compares tool calls field by field.
pub extend ToolCall with Eq::{equal, not_equal}

///|
/// Debug representation of a tool call.
pub extend ToolCall with @debug.Debug::{to_repr}

///|
/// Parses the model-produced argument string as JSON on demand.
///
/// ```mbt check
/// test {
///   let call : @openai.ToolCall = {
///     id: "call_1",
///     name: "lookup",
///     arguments: "{\"id\":1}",
///   }
///   assert_eq(call.arguments_json(), { "id": 1 })
/// }
/// ```
pub fn ToolCall::arguments_json(self : ToolCall) -> Json raise @json.ParseError {
  @json.parse(self.arguments)
}

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
  tool_calls : Array[ToolCall]?
  tool_call_id : String?
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
  { role: "system", content, name: None, tool_calls: None, tool_call_id: None, }
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
  { role: "user", content, name: None, tool_calls: None, tool_call_id: None, }
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
  {
    role: "assistant",
    content,
    name: None,
    tool_calls: None,
    tool_call_id: None,
  }
}

///|
/// Creates a tool result message associated with one model tool call.
///
/// ```mbt check
/// test {
///   let message = @openai.ChatMessage::tool(tool_call_id="call_1", content="done")
///   assert_eq(message.tool_call_id, Some("call_1"))
/// }
/// ```
pub fn ChatMessage::tool(
  tool_call_id~ : String,
  content~ : String,
) -> ChatMessage {
  {
    role: "tool",
    content,
    name: None,
    tool_calls: None,
    tool_call_id: Some(tool_call_id),
  }
}

///|
/// Creates an assistant message containing function tool calls.
/// When content is absent it is encoded without a content field.
///
/// ```mbt check
/// test {
///   let message = @openai.ChatMessage::assistant_tool_calls([
///     { id: "call_1", name: "lookup", arguments: "{}", },
///   ])
///   assert_eq(message.tool_calls.unwrap().length(), 1)
/// }
/// ```
pub fn ChatMessage::assistant_tool_calls(
  tool_calls : Array[ToolCall],
  content? : String,
) -> ChatMessage {
  {
    role: "assistant",
    content: content.unwrap_or(""),
    name: None,
    tool_calls: Some(tool_calls.copy()),
    tool_call_id: None,
  }
}

///|
/// Input accepted by buffered and streaming Chat Completions operations.
pub(all) struct ChatRequest {
  model : String
  messages : Array[ChatMessage]
  max_tokens : Int?
  temperature : Double?
  tools : Array[ToolDef]?
  tool_choice : Json?
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
  tools? : Array[ToolDef],
  tool_choice? : Json,
  extra? : Map[String, Json],
) -> ChatRequest {
  {
    model,
    messages: messages.map(copy_chat_message),
    max_tokens,
    temperature,
    tools: tools.map(Array::copy),
    tool_choice,
    extra: extra.map(Map::copy).unwrap_or({}),
  }
}

///|
fn copy_chat_message(message : ChatMessage) -> ChatMessage {
  { ..message, tool_calls: message.tool_calls.map(Array::copy), }
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
  tool_calls : Array[ToolCall]
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
  ToolCallDelta(
    index~ : Int,
    id~ : String?,
    name~ : String?,
    arguments~ : String
  )
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
/// Incrementally reconstructs tool calls from streamed chat deltas.
///
/// ```mbt check
/// test {
///   let calls = @openai.ToolCallAccumulator::new()
///   calls.feed(index=0, id="call_1", name="lookup", arguments="{}")
///   assert_eq(calls.finish()[0].arguments, "{}")
/// }
/// ```
pub struct ToolCallAccumulator {
  priv calls : Array[PendingToolCall]
}

///|
/// Creates an empty streamed tool-call accumulator.
pub fn ToolCallAccumulator::new() -> ToolCallAccumulator {
  { calls: [], }
}

///|
/// Adds one tool-call delta. The first supplied id and name for an index win.
pub fn ToolCallAccumulator::feed(
  self : ToolCallAccumulator,
  index~ : Int,
  id? : String,
  name? : String,
  arguments~ : String,
) -> Unit {
  match self.calls.search_by(call => call.index == index) {
    None => {
      self.calls.push({ index, id, name, arguments: StringBuilder(), })
      self.calls.last().unwrap().arguments.write_string(arguments)
    }
    Some(call_index) => {
      let call = self.calls[call_index]
      if call.id is None && id is Some(value) {
        call.id = Some(value)
      }
      if call.name is None && name is Some(value) {
        call.name = Some(value)
      }
      call.arguments.write_string(arguments)
    }
  }
}

///|
/// Returns reconstructed calls ordered by their stream index.
/// Missing ids or names are returned as empty strings.
pub fn ToolCallAccumulator::finish(
  self : ToolCallAccumulator,
) -> Array[ToolCall] {
  let pending = self.calls.copy()
  pending.sort_by((left, right) => left.index - right.index)
  pending.map(call => {
    id: call.id.unwrap_or(""),
    name: call.name.unwrap_or(""),
    arguments: call.arguments.to_string(),
  })
}

///|
priv struct PendingToolCall {
  index : Int
  mut id : String?
  mut name : String?
  arguments : StringBuilder
}

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
  tools : Array[ToolDef]?
  tool_choice : Json?
  extra : Map[String, Json]
  priv tool_outputs : Array[(String, String)]
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
  tools? : Array[ToolDef],
  tool_choice? : Json,
  extra? : Map[String, Json],
) -> ResponseRequest {
  {
    model,
    input,
    instructions,
    max_output_tokens,
    temperature,
    previous_response_id,
    tools: tools.map(Array::copy),
    tool_choice,
    extra: extra.map(Map::copy).unwrap_or({}),
    tool_outputs: [],
  }
}

///|
/// Returns a request with function outputs appended to its input items.
///
/// ```mbt check
/// test {
///   let request = @openai.ResponseRequest::new(model="gpt-4.1", input="continue").with_tool_outputs([
///       ("call_1", "done"),
///     ],
///   )
///   assert_eq(request.input, "continue")
/// }
/// ```
pub fn ResponseRequest::with_tool_outputs(
  self : ResponseRequest,
  outputs : Array[(String, String)],
) -> ResponseRequest {
  { ..self, tool_outputs: self.tool_outputs + outputs, }
}

///|
/// A decoded response together with its original JSON value.
pub(all) struct Response {
  id : String
  status : ResponseStatus
  model : String
  output_text : String
  usage : Usage?
  tool_calls : Array[ToolCall]
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
  FunctionCallArgumentsDelta(item_id~ : String, delta~ : String)
  FunctionCallArgumentsDone(item_id~ : String, arguments~ : String)
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
