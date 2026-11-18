///|
// Raised live failures carry only the redacted diagnostic, including when
// the test runner prints the error directly.
suberror LiveFailure {
  LiveFailure(String)
}

///|
impl Show for LiveFailure with fn output(self, logger) {
  let LiveFailure(message) = self
  logger.write_string(message)
}

///|
trait ExpectedFailure {
  fn describe(Self, String, Array[String]?) -> String
}

///|
impl ExpectedFailure for @openai_sdk.OpenAIFailure with fn describe(
  self,
  operation,
  credentials,
) {
  match self {
    Response(error) =>
      @live_diagnostics.response_failure(operation, error, credentials?)
    Api(head, _, body~) =>
      @live_diagnostics.format(
        operation,
        "API error",
        status=head.status,
        body~,
        credentials?,
      )
    Validation(message) =>
      @live_diagnostics.format(operation, message, credentials?)
  }
}

///|
impl ExpectedFailure for @anthropic_sdk.AnthropicFailure with fn describe(
  self,
  operation,
  credentials,
) {
  match self {
    Response(error) =>
      @live_diagnostics.response_failure(operation, error, credentials?)
    Validation(message) =>
      @live_diagnostics.format(operation, message, credentials?)
  }
}

///|
impl ExpectedFailure for @github_sdk.GitHubFailure with fn describe(
  self,
  operation,
  credentials,
) {
  match self {
    Http(error) =>
      @live_diagnostics.response_failure(operation, error, credentials?)
    GraphqlFailure(head, message~, body~) =>
      @live_diagnostics.format(
        operation,
        message,
        status=head.status,
        body~,
        credentials?,
      )
    Validation(message) =>
      @live_diagnostics.format(operation, message, credentials?)
  }
}

///|
async fn[T, E : ExpectedFailure] expect(
  operation : String,
  call : async () -> Result[T, E],
  credentials? : Array[String],
) -> T {
  try call() catch {
    @http.TransportError::_ as error =>
      raise LiveFailure(
        @live_diagnostics.format(operation, error.message(), credentials?),
      )
    @runtime.InvalidRequest(message~) =>
      raise LiveFailure(
        @live_diagnostics.format(operation, message, credentials?),
      )
    error => raise error
  } noraise {
    Ok(value) => value
    Err(error) => raise LiveFailure(error.describe(operation, credentials))
  }
}

///|
async test "live expect reports operation, status, and redacted body" {
  let head : @http.ResponseHead = {
    status: 402,
    headers: @http.Headers::of([("set-cookie", "hidden-cookie")]),
  }
  let failure : @openai_sdk.OpenAIFailure = Api(
    head,
    { message: "quota", type_: None, param: None, code: Some("402"), },
    body=b"{\"error\":\"fixture-token and other-key\"}",
  )
  try
    expect("chat_completion", () => (Err(failure) : Result[Unit, _]), credentials=[
      "fixture-token", "other-key",
    ])
  catch {
    error =>
      assert_eq(
        error.to_string(),
        "chat_completion: HTTP 402 API error\n{\"error\":\"[redacted] and [redacted]\"}",
      )
  } noraise {
    _ => fail("expected a live failure")
  }
}
