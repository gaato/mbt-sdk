///|
fn is_response_key(key : String) -> Bool {
  match key {
    "model"
    | "input"
    | "instructions"
    | "max_output_tokens"
    | "temperature"
    | "previous_response_id"
    | "tools"
    | "tool_choice"
    | "stream" => true
    _ => false
  }
}

///|
fn is_chat_key(key : String) -> Bool {
  match key {
    "model"
    | "messages"
    | "max_tokens"
    | "temperature"
    | "reasoning_effort"
    | "tools"
    | "tool_choice"
    | "stream"
    | "stream_options" => true
    _ => false
  }
}

///|
fn chat_message_json(message : ChatMessage) -> Json raise @runtime.SdkError {
  let fields : Map[String, Json] = { "role": message.role }
  if !(message.role == "assistant" &&
    message.tool_calls is Some(_) &&
    message.content.is_empty()) {
    fields["content"] = message.content.to_json()
  }
  if message.name is Some(name) {
    fields["name"] = name.to_json()
  }
  match message.role {
    "system" | "user" =>
      if message.tool_calls is Some(_) || message.tool_call_id is Some(_) {
        raise @runtime.Config(
          message.role + " chat message cannot contain tool call fields",
        )
      }
    "assistant" => {
      if message.tool_call_id is Some(_) {
        raise @runtime.Config(
          "assistant chat message cannot contain tool_call_id",
        )
      }
      if message.tool_calls is Some(calls) {
        fields["tool_calls"] = calls
          .map(call => {
            @gen.ChatCompletionMessageToolCall::new(
              id=call.id,
              function=@gen.ChatCompletionMessageToolCallFunction::new(
                name=call.name,
                arguments=call.arguments,
              ),
            ).to_json()
          })
          .to_json()
      }
    }
    "tool" => {
      if message.tool_calls is Some(_) {
        raise @runtime.Config("tool chat message cannot contain tool_calls")
      }
      match message.tool_call_id {
        Some(tool_call_id) => fields["tool_call_id"] = tool_call_id.to_json()
        None => raise @runtime.Config("tool chat message requires tool_call_id")
      }
    }
    role => raise @runtime.Config("unsupported chat message role: " + role)
  }
  Json::object(fields)
}

///|
fn chat_tool_json(tool : ToolDef) -> Json {
  @gen.ChatCompletionTool::new(
    function=@gen.FunctionObject::new(
      name=tool.name,
      parameters=tool.parameters,
      description?=tool.description,
      strict?=tool.strict,
    ),
  ).to_json()
}

///|
fn response_tool(tool : ToolDef) -> @gen.Tool {
  @gen.Function(
    @gen.FunctionTool::new(
      type_="function",
      name=tool.name,
      parameters=tool.parameters,
      description?=tool.description,
      strict?=tool.strict,
    ),
  )
}

///|
fn chat_parts(
  request : ChatRequest,
  stream : Bool,
) -> (@gen.CreateChatCompletionRequest, Json) raise @runtime.SdkError {
  for key, _ in request.extra {
    if is_chat_key(key) {
      raise @runtime.Config("extra parameter collides with known key: " + key)
    }
  }
  let fields : Map[String, Json] = {
    "model": request.model,
    "messages": Json::array(request.messages.map(chat_message_json)),
  }
  if request.max_tokens is Some(value) {
    fields["max_tokens"] = value.to_json()
  }
  if request.temperature is Some(value) {
    fields["temperature"] = value.to_json()
  }
  if request.reasoning_effort is Some(value) {
    fields["reasoning_effort"] = value.to_json()
  }
  if request.tools is Some(tools) {
    fields["tools"] = tools.map(chat_tool_json).to_json()
  }
  if request.tool_choice is Some(tool_choice) {
    fields["tool_choice"] = tool_choice
  }
  if stream {
    fields["stream"] = true.to_json()
    fields["stream_options"] = { "include_usage": true }
  }
  let raw = Json::object(fields)
  let generated : @gen.CreateChatCompletionRequest = @json.from_json(raw) catch {
    error =>
      raise @runtime.Config(
        "chat request does not match the generated schema: " + error.to_string(),
      )
  }
  let body = generated.to_json()
  guard body is Object(generated_fields) else {
    raise @runtime.Config("generated chat request must be an object")
  }
  // The upstream generated tool-message type omits the optional `name` field.
  // Restore it after generated validation and encoding until the schema gains it.
  guard generated_fields.get("messages") is Some(Array(messages)) else {
    raise @runtime.Config("generated chat messages must be an array")
  }
  for index, message in request.messages {
    if message.role == "tool" && message.name is Some(name) {
      guard messages.get(index) is Some(Object(fields)) else {
        raise @runtime.Config("generated chat message must be an object")
      }
      fields["name"] = name.to_json()
    }
  }
  for key, value in request.extra {
    generated_fields[key] = value
  }
  (generated, body)
}

///|
fn response_parts(
  request : ResponseRequest,
  stream : Bool,
) -> (@gen.CreateResponse, Json) raise @runtime.SdkError {
  for key, _ in request.extra {
    if is_response_key(key) {
      raise @runtime.Config("extra parameter collides with known key: " + key)
    }
  }
  let input = if request.tool_outputs.is_empty() {
    @gen.CreateResponseInput::Text(request.input)
  } else {
    let items : Array[@gen.InputItem] = [
      @gen.EasyInputMessage(
        @gen.EasyInputMessage::new(
          role=@gen.EasyInputMessageRole::User,
          content=@gen.EasyInputMessageContent::Text(request.input),
        ),
      ),
    ]
    for pair in request.tool_outputs {
      let (call_id, output) = pair
      items.push(
        @gen.FunctionCallOutput(
          @gen.FunctionCallOutputItemParam::new(
            type_="function_call_output",
            call_id~,
            output~,
          ),
        ),
      )
    }
    @gen.CreateResponseInput::InputItemArray(items)
  }
  let generated = @gen.CreateResponse::new(
    model=request.model,
    input~,
    temperature?=request.temperature,
    previous_response_id?=request.previous_response_id,
    max_output_tokens?=request.max_output_tokens,
    instructions?=request.instructions,
    tools?=request.tools.map(tools => tools.map(response_tool)),
    tool_choice?=request.tool_choice,
    stream?=if stream { Some(true) } else { None },
  )
  let body = generated.to_json()
  guard body is Object(fields) else {
    raise @runtime.Config("generated response request must be an object")
  }
  for key, value in request.extra {
    fields[key] = value
  }
  (generated, body)
}
