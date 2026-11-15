///|
/// Transport-independent client. Sharing a runtime Client also shares its retry budget.
pub struct __CLIENT__ {
  priv client : @client.Client
  priv auth : Auth
  priv base_url : String
  priv server_urls : Map[String, String]
}

///|
pub extend __CLIENT__ with @debug.Debug::{to_repr}

///|
pub impl @debug.Debug for __CLIENT__ with fn to_repr(_) {
  @debug.Repr::literal("<__CLIENT__: credentials redacted>")
}

///|
/// Constructs a client using the caller's backend and clock. Retries are conservative
/// unless configured in the ledger. __TIMEOUT_DOC__
/// Backend SendOptions enforce attempts; a supplied timer also bounds runtime waits.
/// __QUERY_WARNING__
/// server_urls maps spec server URLs to replacement URLs, independently of base_url.
pub fn __CLIENT__::new(
  backend : &@http.Backend,
  clock : &@rt.Clock,
  auth~ : Auth = Anonymous,
  base_url~ : String = __BASE_URL__,
  server_urls~ : Map[String, String] = {},
  retry~ : @client.RetryPolicy = default_retry(),
  timer? : &@rt.Timer,
  __TIMEOUT_MS_PARAM__,
  __TOTAL_TIMEOUT_MS_PARAM__,
  max_body_bytes? : Int32,
) -> __CLIENT__ {
  let default = @client.RedirectConfig::default()
  let credential_headers = default.credential_headers.copy()
  __CREDENTIAL_HEADERS__
  let client = @client.Client::new(
    backend, clock, retry~, timer?, __TIMEOUT_MS_ARG__, __TOTAL_TIMEOUT_MS_ARG__,
    max_body_bytes?, redirect={ ..default, credential_headers },
  )
  __CLIENT__::from_client(client, auth~, base_url~, server_urls~)
}

///|
/// Wraps the caller's Client; its policies and retry budget apply.
/// Add this SDK's apiKey header names to the Client's RedirectConfig.credential_headers:
/// from_client cannot enforce their removal on cross-origin redirects.
/// __QUERY_WARNING__
pub fn __CLIENT__::from_client(
  client : @client.Client,
  auth~ : Auth = Anonymous,
  base_url~ : String = __BASE_URL__,
  server_urls~ : Map[String, String] = {},
) -> __CLIENT__ {
  { client, auth, base_url, server_urls: server_urls.copy() }
}

///|
fn route_matches(url : String, template : String, base_url : String) -> Bool {
  let path = try {
    let parsed = @http.Url::parse(url)
    if parsed.is_absolute() {
      let base = @http.Url::parse(base_url)
      if !parsed.same_origin(base) { return false }
      let prefix = base.path.trim_end(chars="/").to_owned()
      if parsed.path == prefix { "/" } else if parsed.path.has_prefix(prefix + "/") {
        parsed.path[prefix.length():].to_owned()
      } else { return false }
    } else { parsed.path }
  } catch { _ => return false }
  let actual = path.split("/").collect()
  let expected = template.split("/").collect()
  if actual.length() != expected.length() { return false }
  for i, part in expected {
    if !(part.has_prefix("{") && part.has_suffix("}")) && part != actual[i] { return false }
  }
  true
}

///|
fn __CLIENT__::operation_base(self : __CLIENT__, server : String) -> String {
  let selected = if server == "" { self.base_url } else { self.server_urls.get(server).unwrap_or(server) }
  try {
    @http.Url::parse(self.base_url).resolve(@http.Url::parse(selected)).to_string()
  } catch { _ => selected }
}

///|
fn __CLIENT__::prepare(self : __CLIENT__, original : @http.Request, operation : String) -> @http.Request {
  let (use_auth, server) = self.operation_config(operation)
  let base = self.operation_base(server)
  let mut request = { ..original, url: @http.join_url(base, original.url) }
  // Do not attach credentials to a next-page URL outside the operation's origin.
  let trusted = try {
    @http.Url::parse(base).same_origin(@http.Url::parse(request.url))
  } catch { _ => false }
  let headers = request.headers__STRIP_HEADERS__
  request = { ..request, headers }
  if use_auth && trusted { request = self.authenticate(request) }
  __IDEMPOTENCY__
  request.attribute(@client.rate_limit_bucket, __PROVIDER__ + ":" + operation)
    .attribute(@client.operation_id, operation)
}

///|
fn response_failure(operation : String, error : @client.ResponseFailure) -> Failure {
  match error {
    @client.UnexpectedStatus(head, body~) => Http({ operation, head, body, typed: typed_error(operation, head, body) })
    _ => Decode(error)
  }
}

///|
/// Buffers and consumes a response; HTTP failures retain status, headers and body.
pub async fn __CLIENT__::send(self : __CLIENT__, request : @http.Request, operation~ : String = self.infer_operation(request)) -> Result[@client.Reply[Bytes], Failure] {
  try {
    let reply = self.client.send(@client.request(self.prepare(request, operation)).response(@client.as_bytes()))
    match reply.body {
      Ok(body) => Ok({ status: reply.status, headers: reply.headers, body, request: reply.request, attributes: reply.attributes })
      Err(error) => Err(response_failure(operation, error))
    }
  } catch {
    @http.TransportError(..) as error => Err(Transport(error))
    error => raise error
  }
}

///|
/// Sends the request and applies the matching generated decoder to a consumed body.
pub async fn[T] __CLIENT__::call(self : __CLIENT__, request : @http.Request, decode : (@http.ResponseHead, Bytes) -> Result[T, @client.ResponseFailure] raise?, operation~ : String = self.infer_operation(request)) -> Result[T, Failure] {
  match self.send(request, operation~) {
    Err(error) => Err(error)
    Ok(reply) => match decode({ status: reply.status, headers: reply.headers }, reply.body) {
      Ok(value) => Ok(value)
      Err(error) => Err(Decode(error))
    }
  }
}

///|
/// Consumes SSE events; stop finishes at a protocol sentinel and closes the body.
/// Callback errors propagate. Streaming bodies are never replayed after consumption.
pub async fn __CLIENT__::stream(self : __CLIENT__, request : @http.Request, receive : async (@sse.SseEvent) -> Unit, stop? : (@sse.SseEvent) -> Bool, operation~ : String = self.infer_operation(request)) -> Result[Unit, Failure] {
  self.stream_with_head(request, receive, stop=(_, event) => match stop {
    Some(predicate) => predicate(event)
    None => false
  }, operation~)
}

///|
async fn __CLIENT__::stream_with_head(self : __CLIENT__, request : @http.Request, receive : async (@sse.SseEvent) -> Unit, stop~ : (@http.ResponseHead, @sse.SseEvent) -> Bool, operation~ : String) -> Result[Unit, Failure] {
  try {
    let reply = self.client.send(@client.request(self.prepare(request, operation)).response(@client.from_head(head => @client.as_sse(receive, stop=event => stop(head, event)))))
    match reply.body {
      Ok(value) => Ok(value)
      Err(error) => Err(response_failure(operation, error))
    }
  } catch {
    @http.TransportError(..) as error => Err(Transport(error))
    error => raise error
  }
}
