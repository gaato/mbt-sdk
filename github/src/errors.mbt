///|
/// The error body returned by the GitHub REST API.
///
/// `status` is a string because that is how GitHub writes it (`"404"`); a
/// numeric value is accepted and rendered the same way. `errors` keeps the raw
/// elements: a `422` reports objects with `resource`, `field`, and `code`,
/// while a few endpoints report plain strings.
///
/// ```mbt check
/// test {
///   let body : @github.ApiErrorBody = {
///     message: "Not Found",
///     documentation_url: Some("https://docs.github.com/rest"),
///     status: Some("404"),
///     errors: None,
///   }
///   assert_eq(body.message, "Not Found")
/// }
/// ```
pub(all) struct ApiErrorBody {
  message : String
  documentation_url : String?
  status : String?
  errors : Array[Json]?
} derive(Eq, @debug.Debug)

///|
/// Compares API error bodies field by field.
pub extend ApiErrorBody with Eq::{equal, not_equal}

///|
/// Debug representation of an API error body.
pub extend ApiErrorBody with @debug.Debug::{to_repr}

///|
/// Extracts GitHub's error body from an HTTP status failure.
///
/// Returns None for transport, decode, and configuration failures, and for a
/// body that is not a GitHub error object — an HTML page from an intermediate
/// proxy, or an empty body.
pub fn api_error(error : @runtime.SdkError) -> ApiErrorBody? {
  let body = match error {
    @runtime.Status(body~, ..) | @runtime.RateLimited(body~, ..) => body
    _ => return None
  }
  try decode_api_error_body(body) catch {
    _ => None
  } noraise {
    value => Some(value)
  }
}

///|
/// Reports the `304` answer to a conditional request.
///
/// A request carrying `if-none-match` or `if-modified-since` is answered with
/// `304 Not Modified` and an empty body, which the runtime classifies as a
/// failure like any other non-2xx status. A cached copy is still valid, and a
/// `304` is not charged against the rate limit.
pub fn is_not_modified(error : @runtime.SdkError) -> Bool {
  error.status() is Some(304)
}

///|
/// Reports a secondary rate limit, which is not the documented hourly quota.
///
/// GitHub answers the hourly quota with `403` or `429` and
/// `x-ratelimit-remaining: 0`; `WindowLimiter` already paces against those
/// headers. A secondary rate limit — too many concurrent requests, too many
/// points in a minute, too much content creation — is a separate mechanism,
/// reported with `403` or `429` plus a `retry-after` header, or a body whose
/// message names it. It leaves `x-ratelimit-remaining` untouched, so no limiter
/// can anticipate it: the caller has to back off and retry.
///
/// The runtime's taxonomy classifies only `429` as `RateLimited`, so a
/// secondary limit delivered as `403` arrives as `Status`. This predicate spans
/// both.
pub fn is_secondary_rate_limit(error : @runtime.SdkError) -> Bool {
  let (status, headers, body) = match error {
    @runtime.Status(status~, headers~, body~) => (status, headers, body)
    @runtime.RateLimited(headers~, body~, ..) => (429, headers, body)
    _ => return false
  }
  guard status == 403 || status == 429 else { return false }
  headers.contains("retry-after") || mentions_secondary_rate_limit(body)
}

///|
/// Reports whether an error body names the secondary rate limit.
fn mentions_secondary_rate_limit(body : Bytes) -> Bool {
  try decode_api_error_body(body) catch {
    _ => false
  } noraise {
    value => value.message.to_lower().contains("secondary rate limit")
  }
}

///|
/// Decodes a GitHub error body, raising when it is not one.
fn decode_api_error_body(body : Bytes) -> ApiErrorBody raise {
  let value = @json.parse(@utf8.decode(body))
  let decoded : ApiErrorJson = @json.from_json(value)
  decoded.0
}

///|
priv struct ApiErrorJson(ApiErrorBody)

///|
impl @json.FromJson for ApiErrorJson with fn from_json(value, path) {
  let obj = @sdkjson.expect_object(value, path)
  ApiErrorJson({
    message: @sdkjson.field(obj, "message", path),
    documentation_url: @sdkjson.opt_field(obj, "documentation_url", path),
    status: decode_status(obj, path),
    errors: @sdkjson.opt_field(obj, "errors", path),
  })
}

///|
/// Reads `status`, which GitHub writes as a string but neighbouring services
/// sometimes write as a number.
fn decode_status(
  obj : Map[String, Json],
  path : @json.JsonPath,
) -> String? raise @json.JsonDecodeError {
  match obj.get("status") {
    None | Some(Null) => None
    Some(String(value)) => Some(value)
    Some(Number(value, ..)) => Some(value.to_int().to_string())
    Some(_) =>
      raise @json.JsonDecodeError(
        (path.add_key("status"), "expected a string or number"),
      )
  }
}
