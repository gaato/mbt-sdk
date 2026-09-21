///|
/// A readable response body. None signals end of stream.
pub(open) trait BodyStream {
  /// Reads the next chunk, or None at end of stream.
  async fn read_some(Self) -> Bytes? raise HttpError
  /// Releases the stream's resources.
  fn close(Self) -> Unit
}

///|
/// Sends requests without interpreting HTTP status codes as errors.
pub(open) trait Transport {
  /// Sends a request and reads its entire response body.
  async fn send(Self, Request) -> Response raise HttpError
  /// Sends a request and returns the response head and a readable body.
  async fn send_stream(Self, Request) -> (ResponseHead, &BodyStream) raise HttpError
}

///|
/// Transport failures, separate from ordinary HTTP response statuses.
pub(all) suberror HttpError {
  Connect(String)
  Timeout(Int)
  Protocol(String)
} derive(Debug)

///|
/// Debug representation of a transport failure.
pub extend HttpError with @debug.Debug::{to_repr}

///|
/// An async request wrapper receiving the next operation in the chain.
pub type Middleware = async (
  Request,
  async (Request) -> Response raise HttpError,
) -> Response raise HttpError

///|
/// Sends through middleware in array order, with the first element outermost.
pub async fn send_with(
  transport : &Transport,
  middleware : Array[Middleware],
  request : Request,
) -> Response raise HttpError {
  let mut next : async (Request) -> Response raise HttpError = request => {
    transport.send(request)
  }
  for i = middleware.length() - 1; i >= 0; i = i - 1 {
    let inner = next
    let wrapper = middleware[i]
    next = request => wrapper(request, inner)
  }
  next(request)
}
