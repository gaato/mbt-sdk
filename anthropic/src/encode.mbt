///|
fn input_role(role : Role) -> @gen.InputMessageRole {
  match role {
    User => @gen.InputMessageRole::User
    Assistant => @gen.InputMessageRole::Assistant
  }
}

///|
fn input_message(message : Message) -> @gen.InputMessage {
  let content = match message.content {
    Text(text) => @gen.InputMessageContent::Text(text)
    Blocks(blocks) => @gen.InputMessageContent::InputContentBlockArray(blocks)
  }
  @gen.InputMessage::new(role=input_role(message.role), content~)
}

///|
fn generated_tool(tool : ToolDef) -> @gen.Tool {
  @gen.Tool::new(
    name=tool.name,
    input_schema=tool.input_schema,
    description?=tool.description,
    strict?=tool.strict,
  )
}

///|
/// The generated request for this facade request, without `extra`.
/// `stream` selects server-sent events; the facade sets it for `stream_message`.
pub fn MessageRequest::to_params(
  self : MessageRequest,
  stream? : Bool = false,
) -> CreateMessageParams {
  @gen.CreateMessageParams::new(
    model=self.model,
    messages=self.messages.map(input_message),
    max_tokens=self.max_tokens,
    system?=self.system.map(text => @gen.CreateMessageParamsSystem::Text(text)),
    temperature?=self.temperature,
    stop_sequences?=self.stop_sequences,
    tools?=self.tools.map(tools => {
      tools.map(tool => {
        @gen.CreateMessageParamsToolsItem::Tool(generated_tool(tool))
      })
    }),
    tool_choice?=self.tool_choice,
    thinking?=self.thinking,
    output_config?=self.output_config,
    metadata?=self.metadata,
    stream?=if stream { Some(true) } else { None },
  )
}

///|
/// The generated token-counting request for this facade request, without `extra`.
pub fn MessageRequest::to_count_tokens_params(
  self : MessageRequest,
) -> @gen.CountMessageTokensParams {
  @gen.CountMessageTokensParams::new(
    model=self.model,
    messages=self.messages.map(input_message),
    system?=self.system.map(text => {
      @gen.CountMessageTokensParamsSystem::Text(text)
    }),
    tools?=self.tools.map(tools => {
      tools.map(tool => {
        @gen.CountMessageTokensParamsToolsItem::Tool(generated_tool(tool))
      })
    }),
    tool_choice?=self.tool_choice,
    thinking?=self.thinking,
    output_config?=self.output_config,
  )
}

///|
/// Keys the facade owns. Anything else in `extra` is merged into the body and
/// validated against the generated schema.
fn is_message_key(key : String) -> Bool {
  match key {
    "model"
    | "max_tokens"
    | "messages"
    | "system"
    | "temperature"
    | "stop_sequences"
    | "tools"
    | "tool_choice"
    | "thinking"
    | "output_config"
    | "metadata"
    | "stream" => true
    _ => false
  }
}

///|
fn[T : ToJson + @json.FromJson] merge_extra(
  params : T,
  extra : Map[String, Json],
  what : String,
) -> (T, Json) raise @runtime.SdkError {
  for key, _ in extra {
    if is_message_key(key) {
      raise @runtime.Config("extra parameter collides with known key: " + key)
    }
  }
  let body = ToJson::to_json(params)
  guard body is Object(fields) else {
    raise @runtime.Config("generated " + what + " must be an object")
  }
  for key, value in extra {
    fields[key] = value
  }
  let validated : T = @json.from_json(body) catch {
    error =>
      raise @runtime.Config(
        what + " does not match the generated schema: " + error.to_string(),
      )
  }
  (validated, body)
}

///|
/// The generated request plus the JSON body actually sent (typed fields, then `extra`).
fn message_body(
  request : MessageRequest,
  stream : Bool,
) -> (CreateMessageParams, Json) raise @runtime.SdkError {
  merge_extra(request.to_params(stream~), request.extra, "message request")
}

///|
fn count_tokens_body(
  request : MessageRequest,
) -> (@gen.CountMessageTokensParams, Json) raise @runtime.SdkError {
  merge_extra(
    request.to_count_tokens_params(),
    request.extra,
    "token count request",
  )
}
