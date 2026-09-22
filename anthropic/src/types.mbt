///|
/// Generated types that the facade uses in its own signatures, re-exported so
/// callers can name them as `@anthropic.X`. Everything else generated from the
/// spec is reachable through `gaato/anthropic/gen`.
pub using @gen {
  type StopReason,
  type Usage,
  type ModelInfo,
  type ListResponseModelInfo,
  type InputContentBlock,
  type ToolChoice,
  type ThinkingConfigParam,
  type OutputConfig,
  type Metadata,
  type MessageDelta,
  type MessageDeltaUsage,
  type CreateMessageParams,
  type MessageStreamEvent,
}

///|
/// Selects the credential header used by the API.
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
/// The error body returned by the Anthropic API.
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
/// Input content as plain text or typed content blocks. A block the generated
/// vocabulary does not know is carried losslessly as `@gen.InputContentBlock::Unknown`.
pub(all) enum InputContent {
  Text(String)
  Blocks(Array[InputContentBlock])
} derive(Eq, Debug)

///|
/// Compares input content, including typed blocks.
pub extend InputContent with Eq::{equal, not_equal}

///|
/// Debug representation of input content.
pub extend InputContent with @debug.Debug::{to_repr}

///|
/// A client tool definition for the Messages API.
///
/// ```mbt check
/// test {
///   let tool = @anthropic.ToolDef::new(name="lookup", input_schema={
///     "type": "object",
///   })
///   assert_eq(tool.name, "lookup")
/// }
/// ```
pub(all) struct ToolDef {
  name : String
  description : String?
  input_schema : Json
  strict : Bool?
} derive(Eq, Debug)

///|
/// Compares tool definitions field by field.
pub extend ToolDef with Eq::{equal, not_equal}

///|
/// Debug representation of a tool definition.
pub extend ToolDef with @debug.Debug::{to_repr}

///|
/// Creates a client tool definition with a JSON Schema input object.
pub fn ToolDef::new(
  name~ : String,
  input_schema~ : Json,
  description? : String,
  strict? : Bool,
) -> ToolDef {
  { name, description, input_schema, strict, }
}

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
/// Creates a user message from typed content blocks (images, documents, tool results, ...).
pub fn Message::user_blocks(blocks : Array[InputContentBlock]) -> Message {
  { role: User, content: Blocks(blocks.copy()), }
}

///|
/// Creates an assistant message from typed content blocks.
pub fn Message::assistant_blocks(blocks : Array[InputContentBlock]) -> Message {
  { role: Assistant, content: Blocks(blocks.copy()), }
}

///|
/// Creates a user message containing one tool result block.
///
/// ```mbt check
/// test {
///   let message = @anthropic.Message::tool_result(
///     tool_use_id="toolu_1",
///     content="done",
///   )
///   assert_eq(message.role, @anthropic.User)
/// }
/// ```
pub fn Message::tool_result(
  tool_use_id~ : String,
  content~ : String,
  is_error? : Bool,
) -> Message {
  {
    role: User,
    content: Blocks([
      @gen.InputContentBlock::ToolResult(
        @gen.RequestToolResultBlock::new(
          tool_use_id~,
          type_="tool_result",
          content=@gen.RequestToolResultBlockContent::Text(content),
          is_error?,
        ),
      ),
    ]),
  }
}

///|
/// Turns a response into the assistant turn to send back, block for block:
/// text, thinking (with its signature), tool use and every other block the
/// API returned are replayed as input blocks. A block the request vocabulary
/// cannot represent is passed through as raw JSON.
pub fn Message::from_response(response : MessageResponse) -> Message {
  let blocks = response.message.content.map(block => {
    let json = block.to_json()
    let converted : InputContentBlock = @json.from_json(json) catch {
      _ => {
        let kind = match json {
          Object(fields) =>
            match fields.get("type") {
              Some(String(kind)) => kind
              _ => ""
            }
          _ => ""
        }
        @gen.InputContentBlock::Unknown(kind, json)
      }
    }
    converted
  })
  { role: Assistant, content: Blocks(blocks), }
}

///|
/// Input accepted by buffered and streaming message creation and by token counting.
///
/// The typed fields cover the common surface; `extra` is merged into the JSON
/// body after the typed fields and validated against the generated schema, so
/// any other documented parameter (`top_p`, `service_tier`, ...) can be passed
/// without a facade change. For full control build a `@gen.CreateMessageParams`
/// and use `Anthropic::create_message_params`.
pub(all) struct MessageRequest {
  model : String
  max_tokens : Int
  messages : Array[Message]
  system : String?
  temperature : Double?
  stop_sequences : Array[String]?
  tools : Array[ToolDef]?
  tool_choice : ToolChoice?
  thinking : ThinkingConfigParam?
  output_config : OutputConfig?
  metadata : Metadata?
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
///     model="claude-opus-5",
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
  tools? : Array[ToolDef],
  tool_choice? : ToolChoice,
  thinking? : ThinkingConfigParam,
  output_config? : OutputConfig,
  metadata? : Metadata,
  extra? : Map[String, Json],
) -> MessageRequest {
  {
    model,
    max_tokens,
    messages: messages.map(copy_message),
    system,
    temperature,
    stop_sequences: stop_sequences.map(Array::copy),
    tools: tools.map(Array::copy),
    tool_choice,
    thinking,
    output_config,
    metadata,
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
/// One output content block. Blocks beyond text, thinking and tool use keep
/// their JSON; the typed form is on `MessageResponse::message`.
pub(all) enum ContentBlock {
  Text(String)
  Thinking(thinking~ : String, signature~ : String)
  RedactedThinking(String)
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
/// A decoded message: the facade view (`content`), the generated view
/// (`message`) and the original JSON (`raw`).
pub(all) struct MessageResponse {
  id : String
  model : String
  role : Role
  content : Array[ContentBlock]
  stop_reason : StopReason?
  usage : Usage
  message : @gen.Message
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
/// The tool uses requested by the response, in content order.
pub fn MessageResponse::tool_uses(
  self : MessageResponse,
) -> Array[(String, String, Json)] {
  let result = []
  for block in self.content {
    if block is ToolUse(id~, name~, input~) {
      result.push((id, name, input))
    }
  }
  result
}

///|
/// One event from a streaming message. Event and delta kinds outside the
/// generated vocabulary retain their raw JSON.
pub(all) enum MessageEvent {
  MessageStart(MessageResponse)
  ContentBlockStart(index~ : Int, block~ : ContentBlock)
  TextDelta(index~ : Int, text~ : String)
  ThinkingDelta(index~ : Int, thinking~ : String)
  SignatureDelta(index~ : Int, signature~ : String)
  InputJsonDelta(index~ : Int, partial_json~ : String)
  ContentBlockStop(index~ : Int)
  MessageDelta(delta~ : MessageDelta, usage~ : MessageDeltaUsage)
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
