///|
/// Selects the credential header used by the Messages API endpoint.
pub(all) enum AuthHeader {
  XApiKey
  Bearer
} derive(Eq, Debug)

///|
/// Compares authentication-header choices.
pub extend AuthHeader with Eq::{equal, not_equal}

///|
/// Debug representation of an authentication-header choice.
pub extend AuthHeader with @debug.Debug::{to_repr}

///|
/// The error body returned by the Anthropic Messages API.
///
/// ```mbt check
/// test {
///   let error : @anthropic.ApiErrorBody = {
///     type_: "invalid_request_error",
///     message: "invalid request",
///   }
///   assert_eq(error.message, "invalid request")
/// }
/// ```
pub(all) struct ApiErrorBody {
  type_ : String
  message : String
} derive(Eq, Debug)

///|
/// Compares API error bodies field by field.
pub extend ApiErrorBody with Eq::{equal, not_equal}

///|
/// Debug representation of an API error body.
pub extend ApiErrorBody with @debug.Debug::{to_repr}

///|
/// A participant in a Messages API conversation.
pub(all) enum Role {
  User
  Assistant
} derive(Eq, Debug)

///|
/// Compares message roles.
pub extend Role with Eq::{equal, not_equal}

///|
/// Debug representation of a message role.
pub extend Role with @debug.Debug::{to_repr}

///|
/// Input content as plain text or unvalidated raw content blocks.
pub(all) enum InputContent {
  Text(String)
  Blocks(Array[Json])
} derive(Eq, Debug)

///|
/// Compares input content, including raw blocks.
pub extend InputContent with Eq::{equal, not_equal}

///|
/// Debug representation of input content.
pub extend InputContent with @debug.Debug::{to_repr}

///|
/// One user or assistant turn sent to the Messages API.
pub(all) struct Message {
  role : Role
  content : InputContent
} derive(Eq, Debug)

///|
/// Compares messages field by field.
pub extend Message with Eq::{equal, not_equal}

///|
/// Debug representation of a message.
pub extend Message with @debug.Debug::{to_repr}

///|
/// Creates a user message containing plain text.
///
/// ```mbt check
/// test {
///   assert_eq(@anthropic.Message::user("hello"), {
///     role: @anthropic.User,
///     content: @anthropic.Text("hello"),
///   })
/// }
/// ```
pub fn Message::user(text : String) -> Message {
  { role: User, content: Text(text), }
}

///|
/// Creates an assistant message containing plain text.
///
/// ```mbt check
/// test {
///   assert_eq(@anthropic.Message::assistant("hello"), {
///     role: @anthropic.Assistant,
///     content: @anthropic.Text("hello"),
///   })
/// }
/// ```
pub fn Message::assistant(text : String) -> Message {
  { role: Assistant, content: Text(text), }
}

///|
/// Input accepted by buffered and streaming message creation.
pub(all) struct MessageRequest {
  model : String
  max_tokens : Int
  messages : Array[Message]
  system : String?
  temperature : Double?
  stop_sequences : Array[String]?
  extra : Map[String, Json]
} derive(Eq, Debug)

///|
/// Compares message requests field by field.
pub extend MessageRequest with Eq::{equal, not_equal}

///|
/// Debug representation of a message request.
pub extend MessageRequest with @debug.Debug::{to_repr}

///|
/// Creates a message request and snapshots its mutable inputs.
///
/// ```mbt check
/// test {
///   let request = @anthropic.MessageRequest::new(
///     model="claude-sonnet-4-5",
///     max_tokens=64,
///     messages=[@anthropic.Message::user("hello")],
///   )
///   assert_eq(request.messages.length(), 1)
/// }
/// ```
pub fn MessageRequest::new(
  model~ : String,
  max_tokens~ : Int,
  messages~ : Array[Message],
  system? : String,
  temperature? : Double,
  stop_sequences? : Array[String],
  extra? : Map[String, Json],
) -> MessageRequest {
  {
    model,
    max_tokens,
    messages: messages.map(copy_message),
    system,
    temperature,
    stop_sequences: stop_sequences.map(Array::copy),
    extra: extra.map(Map::copy).unwrap_or({}),
  }
}

///|
fn copy_message(message : Message) -> Message {
  match message.content {
    Text(text) => { ..message, content: Text(text), }
    Blocks(blocks) => { ..message, content: Blocks(blocks.copy()), }
  }
}

///|
/// One output content block. Unknown block types retain their original JSON.
pub(all) enum ContentBlock {
  Text(String)
  Thinking(String)
  ToolUse(id~ : String, name~ : String, input~ : Json)
  Other(String, Json)
} derive(Eq, Debug)

///|
/// Compares output content blocks.
pub extend ContentBlock with Eq::{equal, not_equal}

///|
/// Debug representation of an output content block.
pub extend ContentBlock with @debug.Debug::{to_repr}

///|
/// Why generation stopped. Unknown values are retained for forward compatibility.
pub(all) enum StopReason {
  EndTurn
  MaxTokens
  StopSequence
  ToolUse
  Refusal
  Unknown(String)
} derive(Eq, Debug)

///|
/// Compares stop reasons, including unknown raw values.
pub extend StopReason with Eq::{equal, not_equal}

///|
/// Debug representation of a stop reason.
pub extend StopReason with @debug.Debug::{to_repr}

///|
/// Token usage reported by a message response.
pub(all) struct Usage {
  input_tokens : Int
  output_tokens : Int
} derive(Eq, Debug)

///|
/// Compares token usage field by field.
pub extend Usage with Eq::{equal, not_equal}

///|
/// Debug representation of token usage.
pub extend Usage with @debug.Debug::{to_repr}

///|
/// A decoded message together with its original JSON value.
pub(all) struct MessageResponse {
  id : String
  model : String
  role : Role
  content : Array[ContentBlock]
  stop_reason : StopReason?
  usage : Usage
  raw : Json
} derive(Eq, Debug)

///|
/// Compares decoded messages field by field.
pub extend MessageResponse with Eq::{equal, not_equal}

///|
/// Debug representation of a decoded message.
pub extend MessageResponse with @debug.Debug::{to_repr}

///|
/// Concatenates text blocks in response order and ignores other block kinds.
///
/// ```mbt check
/// test {
///   let response : @anthropic.MessageResponse = {
///     id: "msg_1",
///     model: "claude-sonnet-4-5",
///     role: @anthropic.Assistant,
///     content: [
///       @anthropic.Text("hello "),
///       @anthropic.Thinking("private"),
///       @anthropic.Text("world"),
///     ],
///     stop_reason: Some(@anthropic.EndTurn),
///     usage: { input_tokens: 1, output_tokens: 2, },
///     raw: null,
///   }
///   assert_eq(response.text(), "hello world")
/// }
/// ```
pub fn MessageResponse::text(self : MessageResponse) -> String {
  let result = StringBuilder()
  for block in self.content {
    if block is Text(text) {
      result.write_string(text)
    }
  }
  result.to_string()
}

///|
/// One event from a streaming message. Unknown event types retain their raw JSON.
pub(all) enum MessageEvent {
  MessageStart(MessageResponse)
  ContentBlockStart(index~ : Int, block~ : ContentBlock)
  TextDelta(index~ : Int, text~ : String)
  ThinkingDelta(index~ : Int, thinking~ : String)
  InputJsonDelta(index~ : Int, partial_json~ : String)
  ContentBlockStop(index~ : Int)
  MessageDelta(stop_reason~ : StopReason?, output_tokens~ : Int?)
  MessageStop
  Ping
  Error(ApiErrorBody)
  Other(String, Json)
} derive(Eq, Debug)

///|
/// Compares message events, including retained unknown JSON.
pub extend MessageEvent with Eq::{equal, not_equal}

///|
/// Debug representation of a message event.
pub extend MessageEvent with @debug.Debug::{to_repr}
