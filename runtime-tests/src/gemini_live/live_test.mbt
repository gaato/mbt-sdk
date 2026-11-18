///|
/// Opt-in only; ordinary gates do not execute this package. Never run with a
/// credential unless the caller explicitly chooses the live test command.
async test "Gemini live countTokens" {
  guard @env.get_env_var("GEMINI_API_KEY") is Some(key) &&
    !key.trim().is_empty() else {
    println("skip: GEMINI_API_KEY is absent")
    return
  }
  let model = @env.get_env_var("GEMINI_MODEL").unwrap_or("gemini-2.5-flash")
  let sdk = @gemini.Gemini::new(
    @backend.AsyncBackend::new(),
    @adapter.AsyncClock::new(),
    auth=ApiKey(key.trim().to_owned()),
    timeout_ms=30000,
  )
  let request = @gen.CountTokensRequest::new(contents=[
    @gen.Content::new(role="user", parts=[
      Text(@gen.PartText::new(text="Hello")),
    ]),
  ])
  let operation = "count_tokens"
  let result = match sdk.count_tokens(model~, request) {
    Ok(result) => result
    Err(Decode(error)) =>
      fail(@live_diagnostics.response_failure(operation, error))
    Err(Http({ head, body, .. })) =>
      fail(
        @live_diagnostics.format(
          operation,
          "API error",
          status=head.status,
          body~,
        ),
      )
    Err(Transport(error)) =>
      fail(@live_diagnostics.format(operation, error.message()))
    Err(Validation(parameter~, message~, ..)) =>
      fail(
        @live_diagnostics.format(operation, "invalid \{parameter}: \{message}"),
      )
    Err(@gemini.Failure::..) => fail(operation + ": request failed")
  }
  assert_true(result.total_tokens.unwrap_or(0) > 0)
}
