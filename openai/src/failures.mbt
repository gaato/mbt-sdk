///|
/// An expected SDK failure. TransportError and unknown user errors remain raised.
#derive(@debug.Debug)
pub(all) enum OpenAIFailure {
  Response(@client.ResponseFailure)
  Validation(String)
  /// An error envelope inside a successful HTTP response or SSE stream.
  Api(@http.ResponseHead, ApiErrorBody, body~ : Bytes)
}

///|
priv suberror ApiError {
  ApiError(@http.ResponseHead, ApiErrorBody, body~ : Bytes)
}

///|
fn check_api_error(
  head : @http.ResponseHead,
  body : Bytes,
) -> Unit raise ApiError {
  let error = try decode_api_error_body(body) catch {
    _ => None
  } noraise {
    error => Some(error)
  }
  if error is Some(error) {
    raise ApiError(head, error, body=body[:1048576].to_owned())
  }
}

///|
fn check_named_error(
  head : @http.ResponseHead,
  kind : String,
  data : String,
) -> Unit raise {
  if kind == "error" {
    let body = @utf8.encode(data)
    check_api_error(head, body)
    let error : ApiErrorJson = @json.from_json(parse_json_body(body)) catch {
      error => raise decode_error(head, message=error.to_string(), body~)
    }
    raise ApiError(head, error.0, body=body[:1048576].to_owned())
  }
}

///|
/// Formats an expected failure with its original response metadata.
pub extend OpenAIFailure with @debug.Debug::{to_repr}

///|
priv suberror DecodeError {
  DecodeError(@client.ResponseFailure)
}

///|
fn decode_error(
  head : @http.ResponseHead,
  message~ : String,
  body~ : Bytes,
) -> DecodeError {
  DecodeError(
    @client.Deserialization(
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
fn[T] take_decode(
  result : Result[T, @client.ResponseFailure],
) -> T raise DecodeError {
  match result {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}

///|
fn[T] decode_reader(
  decode : (Bytes, @http.ResponseHead) -> T raise,
) -> @client.ResponseAs[Result[T, @client.ResponseFailure]] {
  @client.as_bytes().map_with_head((result, head) => {
    match result {
      Err(error) => Err(error)
      Ok(bytes) =>
        Ok(decode(bytes, head)) catch {
          DecodeError(error) => {
            // A valid endpoint result may contain error details (failed Responses).
            // Only classify a standalone envelope when its success decoder rejects it.
            check_api_error(head, bytes)
            Err(error)
          }
          error => raise error
        }
    }
  })
}

///|
// Refine the client's existing decision: its retry limits, headers, budget and
// user policy still apply. A stream is never retried after callback handoff.
fn[T] compatible_retry(
  result : @client.AttemptResult[Result[T, @client.ResponseFailure]],
  context : @client.RetryContext,
) -> @retry.Decision {
  if result is @client.Buffered(reply) &&
    reply.status == 429 &&
    reply.body is Err(@client.UnexpectedStatus(_, body~)) {
    if non_transient_quota(body) {
      return @retry.Stop(@retry.NotRetryable)
    }
  }
  context.default_decision
}

///|
fn non_transient_quota(body : Bytes) -> Bool {
  let raw = parse_json_body(body) catch { _ => return false }
  guard raw is { "error": Object(error), .. } else { return false }
  // Classification needs the business code even when the error has no message.
  let code = match error.get("code") {
    Some(String(code)) => Some(code)
    Some(Number(_, ..) as code) => Some(code.stringify())
    _ => None
  }
  match code {
    Some(
      "insufficient_quota"
      | "1113"
      | "1308"
      | "1310"
      | "insufficient_balance"
      | "account_disabled"
      | "credit_balance_exhausted"
      | "organization_spend_limit_exceeded"
      | "project_spend_limit_exceeded"
      | "organization_usage_limit_exceeded"
      | "Throttling.AllocationQuota"
      | "AllocationQuota.FreeTierOnly"
    ) => true
    _ =>
      match error.get("type") {
        Some(
          String(
            "insufficient_quota"
            | "insufficient_balance"
            | "account_disabled"
          )
        ) => true
        _ => false
      }
  }
}

///|
// This provider's official SDK rule belongs here, alongside its API semantics.
fn default_retry() -> @client.RetryPolicy {
  {
    rule: {
      max_retries: 2,
      statuses: [
        {
          statuses: [Code(408), Code(409), Code(429), Range(500, 599)],
          methods: Any,
        },
      ],
      sent_failures: Any,
      unsent_failures: true,
      override_header: Some("x-should-retry"),
      retry_after: {
        source: MsThenHeader,
        cap: StopAbove(120000),
        zero_means_backoff: true,
      },
      backoff: {
        base_ms: 500,
        max_ms: 8000,
        jitter: Proportional(lo=750, hi=1000),
      },
    },
  }
}

///|
priv suberror ValidationError {
  ValidationError(message~ : String)
}
