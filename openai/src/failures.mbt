///|
/// An expected SDK failure. TransportError and unknown user errors remain raised.
#derive(@debug.Debug)
pub(all) enum OpenAIFailure {
  Response(@client.ResponseFailure)
  Validation(String)
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
          DecodeError(error) => Err(error)
          error => raise error
        }
    }
  })
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
