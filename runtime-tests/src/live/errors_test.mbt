///|
fn is_sdk_error(error : Error) -> Bool {
  match error {
    @model.TransportError(..)
    | @runtime.UnexpectedStatus(_, ..)
    | @runtime.Deserialization(_, ..)
    | @runtime.InvalidRequest(..)
    | @github_sdk.GraphqlFailure(_, ..) => true
    _ => false
  }
}
