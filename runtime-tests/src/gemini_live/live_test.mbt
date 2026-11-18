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
  guard sdk.count_tokens(model~, request) is Ok(result) else {
    fail("Gemini countTokens failed")
  }
  assert_true(result.total_tokens.unwrap_or(0) > 0)
}
