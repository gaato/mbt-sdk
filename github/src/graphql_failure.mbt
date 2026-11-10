///|
/// Expected response, GraphQL and validation failures. TransportError remains raised.
#derive(@debug.Debug)
pub(all) enum GitHubFailure {
  Http(@client.ResponseFailure)
  GraphqlFailure(@http.ResponseHead, message~ : String, body~ : Bytes)
  Validation(String)
}

///|
/// Formats an expected failure with its original HTTP metadata.
pub extend GitHubFailure with @debug.Debug::{to_repr}

///|
priv suberror ExpectedFailure {
  ExpectedFailure(GitHubFailure)
}

///|
fn graphql_failure(
  head : @http.ResponseHead,
  message~ : String,
  body~ : Bytes,
) -> ExpectedFailure {
  ExpectedFailure(
    GraphqlFailure(
      head,
      message~,
      body=if body.length() <= 1048576 {
        body
      } else {
        body[:1048576].to_owned()
      },
    ),
  )
}

///|
priv struct BufferedResponse {
  head : @http.ResponseHead
  body : Bytes
}
