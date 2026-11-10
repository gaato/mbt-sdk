///|
fn is_sdk_error(error : Error) -> Bool {
  match error {
    @http.TransportError(..)
    | @runtime.InvalidRequest(..)
    | OpenAI(_)
    | Anthropic(_)
    | GitHub(_) => true
    _ => false
  }
}
