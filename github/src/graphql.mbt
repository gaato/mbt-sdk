///|
/// Sends a GraphQL query and returns its `data`.
///
/// GitHub's GraphQL API is not generated. In OpenAPI the shape of a response
/// belongs to the operation, which is what `gaato/github/gen` compiles; in
/// GraphQL it belongs to the query document the caller wrote, and the schema
/// only says what is possible. There is no operation-to-type table to generate,
/// so the payload is `Json` and the caller decodes the shape it asked for.
///
///     let data = gh.graphql(
///       query=(
///         #|query($owner: String!, $name: String!) {
///         #|  repository(owner: $owner, name: $name) { stargazerCount }
///         #|}
///       ),
///       variables={ "owner": "gaato", "name": "mbt-sdk" },
///     )
///
/// A GraphQL failure does not use the HTTP status: the reply is `200` with an
/// `errors` array beside a possibly partial `data`. This raises whenever that
/// array is present and non-empty, so an error cannot pass unnoticed; read the
/// array back with `graphql_errors`. Use `graphql_response` instead when the
/// partial `data` of such a reply is worth keeping.
pub async fn GitHub::graphql(
  self : GitHub,
  query~ : String,
  variables? : Json,
  operation_name? : String,
) -> Json raise @runtime.SdkError {
  let response = self.graphql_exchange(query, variables, operation_name)
  let envelope = graphql_envelope(response)
  graphql_data(envelope, response)
}

///|
/// Sends a GraphQL query and returns the whole `{data, errors, extensions}`
/// envelope.
///
/// This raises only for the failures the HTTP status reports — an unauthorized
/// request, a transport error, a body that is not JSON. A GraphQL reply that
/// nulls one field and explains it in `errors` is returned intact, which is the
/// point of this entry point: `graphql` would raise and discard the rest.
pub async fn GitHub::graphql_response(
  self : GitHub,
  query~ : String,
  variables? : Json,
  operation_name? : String,
) -> Json raise @runtime.SdkError {
  let response = self.graphql_exchange(query, variables, operation_name)
  graphql_envelope(response)
}

///|
/// Walks a GraphQL connection, threading its cursor through the variables.
///
/// GraphQL paginates in the body rather than in a `Link` header, and a
/// connection's `pageInfo` sits wherever the query put it — `data.repository`
/// `.issues.pageInfo` for one query, somewhere else for the next. So this takes
/// no path: `page` receives the `data` of each reply and returns that page's
/// items together with the cursor for the following one, which is
/// `pageInfo.endCursor` while `pageInfo.hasNextPage` is true and `None` once it
/// is false. Returning a cursor when `hasNextPage` is false walks off the end of
/// the connection; returning `None` too early stops silently.
///
/// The query takes the cursor as a variable, named `after` unless
/// `cursor_variable` says otherwise, and must declare it nullable so the first
/// page — which is fetched without it — is valid:
///
///     let issues = gh
///       .graphql_paginator(
///         data => {
///           guard data is Object(root) else { ... }
///           ...
///           (nodes, if has_next_page { end_cursor } else { None })
///         },
///         query=(
///           #|query($cursor: String) {
///           #|  repository(owner: "gaato", name: "mbt-sdk") {
///           #|    issues(first: 100, after: $cursor) {
///           #|      nodes { number title }
///           #|      pageInfo { hasNextPage endCursor }
///           #|    }
///           #|  }
///           #|}
///         ),
///         cursor_variable="cursor",
///       )
///       .collect(max=500)
///
/// Each page raises on a non-empty `errors` array exactly as `graphql` does.
pub fn[T] GitHub::graphql_paginator(
  self : GitHub,
  page : (Json) -> (Array[T], String?) raise @runtime.SdkError,
  query~ : String,
  variables? : Json,
  cursor_variable? : String = "after",
  operation_name? : String,
) -> @runtime.Paginator[T, @runtime.SdkError] {
  @runtime.Paginator::with_cursor(cursor => {
    let variables = match cursor {
      None => variables
      Some(cursor) => Some(with_cursor(variables, cursor_variable, cursor))
    }
    let response = self.graphql_exchange(query, variables, operation_name)
    let envelope = graphql_envelope(response)
    let (items, next) = page(graphql_data(envelope, response))
    @runtime.Page::{ items, next, }
  })
}

///|
/// One entry of a GraphQL `errors` array.
///
/// Only `message` is required by the GraphQL specification. `type_` is GitHub's
/// own addition and names the condition — `NOT_FOUND`, `FORBIDDEN`,
/// `RATE_LIMITED` — but it is absent from the errors the query parser raises,
/// and the set of values it can take is not specified, so it stays a `String`.
///
/// `path` and `locations` keep their raw elements: a path mixes field names with
/// list indices, so it is a `Json` array of strings and numbers.
///
/// ```mbt check
/// test {
///   let error : @github.GraphqlError = {
///     message: "Could not resolve to a Repository with the name 'o/r'.",
///     type_: Some("NOT_FOUND"),
///     path: Some(["repository"]),
///     locations: None,
///     extensions: None,
///   }
///   assert_eq(error.type_, Some("NOT_FOUND"))
/// }
/// ```
pub(all) struct GraphqlError {
  message : String
  type_ : String?
  path : Array[Json]?
  locations : Array[Json]?
  extensions : Json?
} derive(Eq, @debug.Debug)

///|
/// Compares GraphQL errors field by field.
pub extend GraphqlError with Eq::{equal, not_equal}

///|
/// Debug representation of a GraphQL error.
pub extend GraphqlError with @debug.Debug::{to_repr}

///|
/// Extracts the GraphQL `errors` array from a failure.
///
/// This is the counterpart of `api_error`. `graphql` reports a non-empty
/// `errors` array as `@runtime.Decode` — the response decoded, it simply did not
/// carry the value that was asked for — and attaches the body, which this reads
/// back:
///
///     if @github.graphql_errors(error) is Some(errors) {
///       for error in errors {
///         if error.type_ is Some("RATE_LIMITED") { ... }
///       }
///     }
///
/// Returns None for a body that is not a GraphQL envelope with errors, which
/// includes every REST-shaped failure of the endpoint: an unauthenticated
/// request is answered `403` with a `message` body that `api_error` reads.
pub fn graphql_errors(error : @runtime.SdkError) -> Array[GraphqlError]? {
  let body = match error {
    @runtime.Decode(body~, ..)
    | @runtime.Status(body~, ..)
    | @runtime.RateLimited(body~, ..) => body
    _ => return None
  }
  try decode_graphql_errors(body) catch {
    _ => None
  } noraise {
    value => Some(value)
  }
}

///|
/// Sends one GraphQL request.
///
/// `accept` is set here because the client default is the REST media type,
/// which this endpoint has no use for. The `x-github-api-version` default rides
/// along; it selects a REST API version and GitHub ignores it for GraphQL,
/// which has no versions.
async fn GitHub::graphql_exchange(
  self : GitHub,
  query : String,
  variables : Json?,
  operation_name : String?,
) -> @http.Response raise @runtime.SdkError {
  self.send(
    @http.Request::post(self.graphql_url)
    .header("accept", "application/json")
    .json_body(
      @sdkjson.ObjBuilder::new()
      .field("query", query)
      .opt("variables", variables)
      .opt("operationName", operation_name)
      .build(),
    ),
  )
}

///|
/// Parses a GraphQL reply body.
fn graphql_envelope(response : @http.Response) -> Json raise @runtime.SdkError {
  response.json() catch {
    error =>
      raise @runtime.Decode(message=error.to_string(), body=response.body)
  }
}

///|
/// Reads `data` out of an envelope, raising when the reply reports errors.
///
/// The raise is `@runtime.Decode` rather than `@runtime.Status`: the request
/// succeeded at the HTTP level, so reporting it as a status would put a `200` in
/// `SdkError::status` and mislead anything that branches on one. `Decode` is
/// also not retryable, which is right even for `RATE_LIMITED` — GraphQL's point
/// budget refills on the hour and carries no `retry-after`, so an immediate
/// retry only spends the policy's attempts. The response's `x-ratelimit-reset`
/// has already reached the limiter, which paces the next request.
fn graphql_data(
  envelope : Json,
  response : @http.Response,
) -> Json raise @runtime.SdkError {
  if envelope_errors(envelope) is Some(errors) && errors.length() > 0 {
    raise @runtime.Decode(
      message=graphql_error_message(errors),
      body=response.body,
    )
  }
  guard envelope is Object(fields) else {
    raise @runtime.Decode(
      message="graphql response is not an object",
      body=response.body,
    )
  }
  match fields.get("data") {
    Some(Null) | None =>
      raise @runtime.Decode(
        message="graphql response carries neither data nor errors",
        body=response.body,
      )
    Some(data) => data
  }
}

///|
/// Summarises an errors array for the message of a raised failure.
fn graphql_error_message(errors : Array[GraphqlError]) -> String {
  let head = "graphql: " + errors[0].message
  if errors.length() > 1 {
    head + " (and " + (errors.length() - 1).to_string() + " more)"
  } else {
    head
  }
}

///|
/// Reads the `errors` array of an already parsed envelope.
fn envelope_errors(envelope : Json) -> Array[GraphqlError]? {
  try decode_envelope_errors(envelope) catch {
    _ => None
  } noraise {
    value => Some(value)
  }
}

///|
/// Decodes the `errors` array of a reply body, raising when there is none.
fn decode_graphql_errors(body : Bytes) -> Array[GraphqlError] raise {
  decode_envelope_errors(@json.parse(@utf8.decode(body)))
}

///|
/// Decodes the `errors` array of an envelope, raising when there is none.
fn decode_envelope_errors(envelope : Json) -> Array[GraphqlError] raise {
  let decoded : GraphqlEnvelope = @json.from_json(envelope)
  decoded.0
}

///|
/// Builds the variables of the page after the first.
///
/// The caller's map is copied rather than extended, so a paginator does not
/// mutate the value it was handed and a retry of one page sees the same
/// variables twice.
fn with_cursor(
  variables : Json?,
  name : String,
  cursor : String,
) -> Json raise @runtime.SdkError {
  let fields = match variables {
    None | Some(Null) => Map([])
    Some(Object(source)) => source.copy()
    Some(_) =>
      raise @runtime.Config(
        "graphql variables must be an object to carry the \{name} cursor",
      )
  }
  fields[name] = Json(cursor)
  Json::object(fields)
}

///|
priv struct GraphqlEnvelope(Array[GraphqlError])

///|
impl @json.FromJson for GraphqlEnvelope with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  let errors : Array[GraphqlErrorJson] = @sdkjson.field(obj, "errors", path)
  GraphqlEnvelope(errors.map(error => error.0))
}

///|
priv struct GraphqlErrorJson(GraphqlError)

///|
impl @json.FromJson for GraphqlErrorJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  GraphqlErrorJson({
    message: @sdkjson.field(obj, "message", path),
    type_: @sdkjson.opt_field(obj, "type", path),
    path: @sdkjson.opt_field(obj, "path", path),
    locations: @sdkjson.opt_field(obj, "locations", path),
    extensions: @sdkjson.opt_field(obj, "extensions", path),
  })
}
