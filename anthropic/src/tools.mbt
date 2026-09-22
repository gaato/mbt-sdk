///|
/// Lets the model decide whether to call a tool.
pub fn tool_choice_auto(disable_parallel_tool_use? : Bool) -> ToolChoice {
  @gen.ToolChoice::Auto(
    @gen.ToolChoiceAuto::new(type_="auto", disable_parallel_tool_use?),
  )
}

///|
/// Requires the model to call some tool.
pub fn tool_choice_any(disable_parallel_tool_use? : Bool) -> ToolChoice {
  @gen.ToolChoice::Any(
    @gen.ToolChoiceAny::new(type_="any", disable_parallel_tool_use?),
  )
}

///|
/// Requires the model to call the named tool.
pub fn tool_choice_tool(
  name : String,
  disable_parallel_tool_use? : Bool,
) -> ToolChoice {
  @gen.ToolChoice::Tool(
    @gen.ToolChoiceTool::new(name~, type_="tool", disable_parallel_tool_use?),
  )
}

///|
/// Forbids tool calls.
pub fn tool_choice_none() -> ToolChoice {
  @gen.ToolChoice::None(@gen.ToolChoiceNone::new(type_="none"))
}

///|
/// Reconstructs streamed tool-use inputs by content block index.
///
/// ```mbt check
/// test {
///   let tools = @anthropic.ToolUseAccumulator::new()
///   tools.feed(
///     @anthropic.ContentBlockStart(
///       index=0,
///       block=@anthropic.ToolUse(id="toolu_1", name="lookup", input={}),
///     ),
///   )
///   tools.feed(@anthropic.InputJsonDelta(index=0, partial_json="{}"))
///   tools.feed(@anthropic.ContentBlockStop(index=0))
///   assert_eq(tools.finish()[0].2, {})
/// }
/// ```
pub struct ToolUseAccumulator {
  priv calls : Array[PendingToolUse]
}

///|
/// Creates an empty tool-use accumulator.
pub fn ToolUseAccumulator::new() -> ToolUseAccumulator {
  { calls: [], }
}

///|
/// Consumes one message event. Invalid partial JSON is retained without raising.
pub fn ToolUseAccumulator::feed(
  self : ToolUseAccumulator,
  event : MessageEvent,
) -> Unit {
  match event {
    ContentBlockStart(index~, block=ToolUse(id~, name~, ..)) => {
      let pending : PendingToolUse = {
        index,
        id,
        name,
        arguments: StringBuilder(),
        complete: false,
      }
      match self.calls.search_by(call => call.index == index) {
        Some(position) => self.calls[position] = pending
        None => self.calls.push(pending)
      }
    }
    InputJsonDelta(index~, partial_json~) =>
      if self.calls.search_by(call => call.index == index) is Some(position) {
        self.calls[position].arguments.write_string(partial_json)
      }
    ContentBlockStop(index~) =>
      if self.calls.search_by(call => call.index == index) is Some(position) {
        self.calls[position].complete = true
      }
    _ => ()
  }
}

///|
/// Returns completed tool uses ordered by block index.
/// Invalid accumulated JSON raises `@json.ParseError` here rather than from `feed`.
pub fn ToolUseAccumulator::finish(
  self : ToolUseAccumulator,
) -> Array[(String, String, Json)] raise @json.ParseError {
  let pending = self.calls.filter(call => call.complete)
  pending.sort_by((left, right) => left.index - right.index)
  pending.map(call => {
    (call.id, call.name, @json.parse(call.arguments.to_string()))
  })
}

///|
priv struct PendingToolUse {
  index : Int
  id : String
  name : String
  arguments : StringBuilder
  mut complete : Bool
}
