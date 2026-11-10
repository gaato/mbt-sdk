///|
// This adapter keeps opt-in live fallback diagnostics effectful. It only lifts
// SDK values; it never catches transport failures or callback exceptions.
suberror LiveFailure {
  OpenAI(@openai_sdk.OpenAIFailure)
  Anthropic(@anthropic_sdk.AnthropicFailure)
  GitHub(@github_sdk.GitHubFailure)
}

///|
trait ExpectedFailure {
  fn raised(Self) -> LiveFailure
}

///|
impl ExpectedFailure for @openai_sdk.OpenAIFailure with fn raised(self) {
  OpenAI(self)
}

///|
impl ExpectedFailure for @anthropic_sdk.AnthropicFailure with fn raised(self) {
  Anthropic(self)
}

///|
impl ExpectedFailure for @github_sdk.GitHubFailure with fn raised(self) {
  GitHub(self)
}

///|
fn[T, E : ExpectedFailure] expect(result : Result[T, E]) -> T raise LiveFailure {
  match result {
    Ok(value) => value
    Err(error) => raise error.raised()
  }
}

///|
fn openai_value(error : Error) -> @openai_sdk.OpenAIFailure? {
  match error {
    OpenAI(value) => Some(value)
    _ => None
  }
}

///|
fn anthropic_value(error : Error) -> @anthropic_sdk.AnthropicFailure? {
  match error {
    Anthropic(value) => Some(value)
    _ => None
  }
}

///|
fn github_value(error : Error) -> @github_sdk.GitHubFailure? {
  match error {
    GitHub(value) => Some(value)
    _ => None
  }
}

///|
fn status_of(error : Error) -> Int32? {
  match error {
    OpenAI(@openai_sdk.Response(value))
    | Anthropic(@anthropic_sdk.Response(value))
    | GitHub(@github_sdk.Http(value)) => @runtime.status_of(value)
    // A GraphQL field error retains HTTP 200 rather than inventing a failure status.
    _ => None
  }
}
