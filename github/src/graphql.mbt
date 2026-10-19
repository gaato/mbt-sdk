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
///
/// Three kinds of error are recognised inside the retry loop, before the reply
/// is returned (see `GitHubRetry`):
///
/// - a `RATE_LIMITED` error (the point budget is spent) is raised as
///   `@runtime.RateLimited` with the reply's headers and body, and retried
///   once, one second after `x-ratelimit-reset`;
/// - an error naming the secondary rate limit is raised as
///   `@runtime.RateLimited` as well, and retried after `retry-after` or at
///   least a minute;
/// - "Something went wrong while executing your query" is raised as
///   `@runtime.Decode` and retried with the policy's backoff, but only when
///   the document holds no mutation, since a mutation may have been applied.
///
/// Requests are metered and paced in the `"graphql"` bucket, or
/// `"graphql:mutation"` for a document holding a mutation.
pub async fn GitHub::graphql(
  self : GitHub,
  query~ : String,
  variables? : Json,
  operation_name? : String,
) -> Json raise @runtime.SdkError {
  let (response, envelope) = self.graphql_exchange(
    query, variables, operation_name,
  )
  graphql_data(envelope, response)
}

///|
/// Sends a GraphQL query and returns the whole `{data, errors, extensions}`
/// envelope.
///
/// This raises for the failures the HTTP status reports — an unauthorized
/// request, a transport error, a body that is not JSON — and for the errors
/// `graphql` retries once their retries run out: a rate limit, and a transient
/// failure of a document without a mutation. Any other GraphQL reply, such as
/// one that nulls one field and explains it in `errors`, is returned intact,
/// which is the point of this entry point: `graphql` would raise and discard
/// the rest.
pub async fn GitHub::graphql_response(
  self : GitHub,
  query~ : String,
  variables? : Json,
  operation_name? : String,
) -> Json raise @runtime.SdkError {
  self.graphql_exchange(query, variables, operation_name).1
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
/// Each page raises on a non-empty `errors` array, and is retried, exactly as
/// `graphql` does.
pub fn[T] GitHub::graphql_paginator(
  self : GitHub,
  page : (Json) -> (Array[T], String?) raise @runtime.SdkError,
  query~ : String,
  variables? : Json,
  cursor_variable~ : String = "after",
  operation_name? : String,
) -> @runtime.Paginator[T, @runtime.SdkError] {
  @runtime.Paginator::with_cursor(cursor => {
    let variables = match cursor {
      None => variables
      Some(cursor) => Some(with_cursor(variables, cursor_variable, cursor))
    }
    let (response, envelope) = self.graphql_exchange(
      query, variables, operation_name,
    )
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
/// carry the value that was asked for — or, for a rate limit, as
/// `@runtime.RateLimited`, and attaches the body to either, which this reads
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
/// The bucket of a GraphQL document that holds no mutation.
let graphql_bucket : String = "graphql"

///|
/// The bucket of a GraphQL document that holds a mutation: its own name, so
/// `GitHubRetry` knows not to retry a transient failure of it, while
/// `x-ratelimit-resource: graphql` lets it share the `"graphql"` window.
let graphql_mutation_bucket : String = "graphql:mutation"

///|
/// Sends one GraphQL request and parses its reply.
///
/// `accept` is set here because the client default is the REST media type,
/// which this endpoint has no use for. The `x-github-api-version` default rides
/// along; it selects a REST API version and GitHub ignores it for GraphQL,
/// which has no versions.
///
/// The reply is parsed and checked inside the client's attempt loop (`accept`)
/// so a rate limit or a transient failure reported in a `200` is retried like
/// an error status; the envelope parsed there is handed back so it is not
/// parsed twice.
async fn GitHub::graphql_exchange(
  self : GitHub,
  query : String,
  variables : Json?,
  operation_name : String?,
) -> (@http.Response, Json) raise @runtime.SdkError {
  let mutation = is_mutation_document(query)
  let parsed : Ref[Json?] = { val: None, }
  let response = self.client.send(
    @http.Request::post(self.graphql_url)
    .header("accept", "application/json")
    .json_body(
      @sdkjson.ObjBuilder::new()
      .field("query", query)
      .opt("variables", variables)
      .opt("operationName", operation_name)
      .build(),
    ),
    bucket=if mutation { graphql_mutation_bucket } else { graphql_bucket },
    accept=response => {
      parsed.val = None
      let envelope = graphql_envelope(response)
      check_graphql_reply(envelope, response, mutation~)
      parsed.val = Some(envelope)
    },
  )
  match parsed.val {
    Some(envelope) => (response, envelope)
    None => (response, graphql_envelope(response))
  }
}

///|
/// Raises, for `GitHubRetry` to decide, the errors of a `200` reply that are
/// worth another attempt: a spent point budget (`RATE_LIMITED`) or a secondary
/// rate limit as `RateLimited` with the reply's headers and body, and a
/// transient failure of a document without a mutation as `Decode`. Any other
/// reply passes.
fn check_graphql_reply(
  envelope : Json,
  response : @http.Response,
  mutation~ : Bool,
) -> Unit raise @runtime.SdkError {
  guard envelope_errors(envelope) is Some(errors) && errors.length() > 0 else {
    return
  }
  if has_condition(errors, GraphqlRateLimited) ||
    has_condition(errors, GraphqlSecondary) {
    raise @runtime.RateLimited(
      retry_after_ms=@http.retry_after_ms(response.headers),
      headers=response.headers,
      body=response.body,
    )
  }
  if !mutation && has_condition(errors, GraphqlTransient) {
    raise @runtime.Decode(
      message=graphql_error_message(errors),
      body=response.body,
    )
  }
}

///|
/// The GraphQL errors that the retry loop treats specially.
priv enum GraphqlCondition {
  /// `type: "RATE_LIMITED"`: the primary point budget is spent.
  GraphqlRateLimited
  /// A message naming the secondary rate limit.
  GraphqlSecondary
  /// "Something went wrong while executing your query", which octokit's
  /// `plugin-retry` retries as if it were a `500`.
  GraphqlTransient
}

///|
/// Whether one GraphQL error is of this kind.
fn GraphqlCondition::matches(
  self : GraphqlCondition,
  error : GraphqlError,
) -> Bool {
  match self {
    GraphqlRateLimited => error.type_ is Some("RATE_LIMITED")
    GraphqlSecondary => names_secondary_rate_limit(error.message)
    GraphqlTransient =>
      error.message.contains("Something went wrong while executing your query")
  }
}

///|
/// Whether a reply body is a GraphQL envelope with an error of this kind.
fn graphql_reply_has(body : Bytes, condition : GraphqlCondition) -> Bool {
  try decode_graphql_errors(body) catch {
    _ => false
  } noraise {
    errors => has_condition(errors, condition)
  }
}

///|
/// Whether any of the errors is of this kind.
fn has_condition(
  errors : Array[GraphqlError],
  condition : GraphqlCondition,
) -> Bool {
  errors.iter().any(error => condition.matches(error))
}

///|
/// Whether a GraphQL document holds a mutation operation, so that a failure
/// of it must not be retried.
///
/// The document is scanned for the keyword `mutation` outside every brace,
/// parenthesis and bracket, skipping what GraphQL ignores (whitespace,
/// commas, a byte order mark, `#` comments) and string values. That finds a
/// mutation that is not the first definition — after a fragment, or beside a
/// query in a document whose `operationName` picks it — which a look at the
/// first keyword alone would miss. A query shorthand (`{ … }`), `query` and
/// `subscription` are not mutations; keywords are case-sensitive, so a type
/// condition `on Mutation` is not one either.
fn is_mutation_document(document : String) -> Bool {
  let chars = document.to_array()
  let length = chars.length()
  let mut depth = 0
  let mut i = 0
  while i < length {
    let c = chars[i]
    if c == '#' {
      while i < length && chars[i] != '\n' && chars[i] != '\r' {
        i += 1
      }
    } else if c == '"' {
      i = skip_string(chars, i)
    } else if c == '{' || c == '(' || c == '[' {
      depth += 1
      i += 1
    } else if c == '}' || c == ')' || c == ']' {
      depth = (depth - 1).max(0)
      i += 1
    } else if is_name_start(c) {
      let start = i
      while i < length &&
            (is_name_start(chars[i]) || (chars[i] >= '0' && chars[i] <= '9')) {
        i += 1
      }
      if depth == 0 &&
        i - start == 8 &&
        String::from_array(chars[start:i]) == "mutation" {
        return true
      }
    } else {
      i += 1
    }
  }
  false
}

///|
/// Whether a character can start a GraphQL name.
fn is_name_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

///|
/// The index just past the string value starting at `start`: a block string
/// (`"""…"""`, where only `\"""` escapes), or a string that ends at an
/// unescaped quote or at the end of its line. An unterminated string runs to
/// the end of the document.
fn skip_string(chars : Array[Char], start : Int32) -> Int32 {
  let length = chars.length()
  let block = start + 2 < length &&
    chars[start + 1] == '"' &&
    chars[start + 2] == '"'
  if block {
    let mut i = start + 3
    while i < length {
      if chars[i] == '\\' &&
        i + 3 < length &&
        chars[i + 1] == '"' &&
        chars[i + 2] == '"' &&
        chars[i + 3] == '"' {
        i += 4
      } else if chars[i] == '"' &&
        i + 2 < length &&
        chars[i + 1] == '"' &&
        chars[i + 2] == '"' {
        return i + 3
      } else {
        i += 1
      }
    }
    return length
  }
  let mut i = start + 1
  while i < length {
    match chars[i] {
      '\\' => i += 2
      '"' => return i + 1
      '\n' | '\r' => return i
      _ => i += 1
    }
  }
  length
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
/// `SdkError::status` and mislead anything that branches on one. The errors
/// worth retrying never get here: `check_graphql_reply` raised them inside the
/// retry loop.
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
