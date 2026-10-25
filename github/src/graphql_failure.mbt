///|
/// A GraphQL envelope that cannot satisfy the query. The original HTTP head
/// and bytes are retained, including for API rate limits reported with HTTP 200.
#derive(@debug.Debug)
pub(all) suberror GraphqlFailure {
  GraphqlFailure(@model.ResponseHead, message~ : String, body~ : Bytes)
}

///|
/// Formats the original response head, error message and body for diagnostics.
pub extend GraphqlFailure with @debug.Debug::{to_repr}

///|
priv struct BufferedResponse {
  head : @model.ResponseHead
  body : Bytes
}
