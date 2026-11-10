///|
// Preserve the historical behavior suite's control flow through a test-only
// adapter. New contract tests exercise Result values directly; this adapter
// never catches TransportError or exceptions raised by callbacks.
suberror TestResponseFailure {
  TestResponseFailure(@runtime.ResponseFailure)
}

///|
fn[T] expect(result : Result[T, @openai_sdk.OpenAIFailure]) -> T raise {
  match result {
    Ok(value) => value
    Err(@openai_sdk.Response(error)) => raise TestResponseFailure(error)
    Err(@openai_sdk.Validation(message)) =>
      raise @runtime.InvalidRequest(message~)
  }
}

///|
fn status_of(error : Error) -> Int32? {
  match error {
    TestResponseFailure(error) => @runtime.status_of(error)
    _ => None
  }
}

///|
fn api_error(error : Error) -> @openai_sdk.ApiErrorBody? {
  match error {
    TestResponseFailure(error) =>
      @openai_sdk.api_error(@openai_sdk.Response(error))
    _ => None
  }
}
