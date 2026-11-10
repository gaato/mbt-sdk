///|
// Preserve the historical behavior suite's control flow through a test-only
// adapter. New contract tests exercise Result values directly; this adapter
// never catches TransportError or exceptions raised by callbacks.
suberror TestResponseFailure {
  TestResponseFailure(@runtime.ResponseFailure)
}

///|
fn[T] expect(result : Result[T, @github_sdk.GitHubFailure]) -> T raise {
  match result {
    Ok(value) => value
    Err(@github_sdk.Http(error)) => raise TestResponseFailure(error)
    Err(@github_sdk.Validation(message)) =>
      raise @runtime.InvalidRequest(message~)
    Err(@github_sdk.GraphqlFailure(head, message~, body~)) =>
      raise TestGraphqlFailure(head, message~, body~)
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
fn api_error(error : Error) -> @github_sdk.ApiErrorBody? {
  match error {
    TestResponseFailure(error) => @github_sdk.api_error(@github_sdk.Http(error))
    _ => None
  }
}

///|
suberror TestGraphqlFailure {
  TestGraphqlFailure(@http.ResponseHead, message~ : String, body~ : Bytes)
}

///|
fn failure_value(error : Error) -> @github_sdk.GitHubFailure? {
  match error {
    TestGraphqlFailure(head, message~, body~) =>
      Some(@github_sdk.GraphqlFailure(head, message~, body~))
    TestResponseFailure(error) => Some(@github_sdk.Http(error))
    _ => None
  }
}

///|
fn graphql_errors(error : Error) -> Array[@github_sdk.GraphqlError]? {
  failure_value(error).bind(@github_sdk.graphql_errors)
}

///|
fn is_secondary_rate_limit(error : Error) -> Bool {
  failure_value(error).map(@github_sdk.is_secondary_rate_limit).unwrap_or(false)
}

///|
fn is_not_modified(error : Error) -> Bool {
  failure_value(error).map(@github_sdk.is_not_modified).unwrap_or(false)
}

///|
fn http_outcome(error : Error) -> @runtime.AttemptOutcome {
  match error {
    TestResponseFailure(
      @runtime.UnexpectedStatus(head, ..)
      | @runtime.Deserialization(head, ..)
    ) =>
      @runtime.AttemptOutcome::Response(
        status=head.status,
        headers=head.headers,
      )
    @http.TransportError(..) as error => @runtime.AttemptOutcome::Failure(error)
    _ =>
      @runtime.AttemptOutcome::Response(
        status=200,
        headers=@http.Headers::empty(),
      )
  }
}
