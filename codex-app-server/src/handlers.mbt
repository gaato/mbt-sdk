///|
/// Approval and user-input callbacks. Absent callbacks return method-not-found;
/// the SDK never selects an approval decision on behalf of its caller.
pub struct Handlers {
  priv command : (async (@protocol.CommandExecutionRequestApprovalParams) -> Result[
    @protocol.CommandExecutionRequestApprovalResponse,
    @jsonrpc.RpcError,
  ])?
  priv file_change : (async (@protocol.FileChangeRequestApprovalParams) -> Result[
    @protocol.FileChangeRequestApprovalResponse,
    @jsonrpc.RpcError,
  ])?
  priv permissions : (async (@protocol.PermissionsRequestApprovalParams) -> Result[
    @protocol.PermissionsRequestApprovalResponse,
    @jsonrpc.RpcError,
  ])?
  priv user_input : (async (@protocol.ToolRequestUserInputParams) -> Result[
    @protocol.ToolRequestUserInputResponse,
    @jsonrpc.RpcError,
  ])?
}

///|
/// Registers only the server requests the application can handle.
pub fn Handlers::new(
  command? : async (@protocol.CommandExecutionRequestApprovalParams) -> Result[
    @protocol.CommandExecutionRequestApprovalResponse,
    @jsonrpc.RpcError,
  ],
  file_change? : async (@protocol.FileChangeRequestApprovalParams) -> Result[
    @protocol.FileChangeRequestApprovalResponse,
    @jsonrpc.RpcError,
  ],
  permissions? : async (@protocol.PermissionsRequestApprovalParams) -> Result[
    @protocol.PermissionsRequestApprovalResponse,
    @jsonrpc.RpcError,
  ],
  user_input? : async (@protocol.ToolRequestUserInputParams) -> Result[
    @protocol.ToolRequestUserInputResponse,
    @jsonrpc.RpcError,
  ],
) -> Handlers {
  { command, file_change, permissions, user_input, }
}

///|
async fn[P : @json.FromJson, R : ToJson] handle(
  handler : async (P) -> Result[R, @jsonrpc.RpcError],
  params : Json?,
) -> Result[Json, @jsonrpc.RpcError] {
  let decoded : P = @json.from_json(params.unwrap_or(Json::null())) catch {
    error =>
      return Err(@jsonrpc.RpcError::invalid_params(message=error.to_string()))
  }
  match handler(decoded) {
    Ok(response) => Ok(response.to_json())
    Err(error) => Err(error)
  }
}

///|
async fn Handlers::dispatch(
  self : Handlers,
  name : String,
  params : Json?,
) -> Result[Json, @jsonrpc.RpcError] {
  match
    (name, self.command, self.file_change, self.permissions, self.user_input) {
    ("item/commandExecution/requestApproval", Some(handler), _, _, _) =>
      handle(handler, params)
    ("item/fileChange/requestApproval", _, Some(handler), _, _) =>
      handle(handler, params)
    ("item/permissions/requestApproval", _, _, Some(handler), _) =>
      handle(handler, params)
    ("item/tool/requestUserInput", _, _, _, Some(handler)) =>
      handle(handler, params)
    _ => Err(@jsonrpc.RpcError::method_not_found(name))
  }
}
