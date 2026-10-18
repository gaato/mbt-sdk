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
/// The step of an exchange a transport failure happened in.
pub(all) enum Phase {
  /// Waiting for a connection slot, when the transport caps connections.
  Pool
  /// Resolving the host, connecting, and the TLS handshake.
  Dial
  /// Sending the request line, headers and body.
  Write
  /// Waiting for and reading the response head.
  Head
  /// Reading the response body.
  Body
  /// Somewhere in the exchange: the layer reporting the failure cannot see
  /// which step, as with fetch or a deadline wrapped around a whole transport.
  Unknown
} derive(Eq, Debug)

///|
/// Equality for phases.
pub extend Phase with Eq::{equal, not_equal}

///|
/// Debug representation of a phase.
pub extend Phase with @debug.Debug::{to_repr}

///|
/// Transport failures, separate from ordinary HTTP response statuses.
pub(all) suberror HttpError {
  /// No connection was made, so no byte of the request was sent: the host
  /// did not resolve, the connection or TLS handshake failed, or the
  /// transport is closed.
  Connect(String)
  /// A time limit of `ms` milliseconds ran out during `phase`.
  Timeout(phase~ : Phase, ms~ : Int32)
  /// Sending or receiving failed after the connection was made, in `phase`
  /// (`Write`, `Head`, `Body`, or `Unknown`).
  Network(phase~ : Phase, message~ : String)
  /// A malformed request or response, or one the transport refused.
  Protocol(String)
} derive(Debug)

///|
/// Debug representation of a transport failure.
pub extend HttpError with @debug.Debug::{to_repr}

///|
/// Whether the failure proves that no byte of the request was sent, so the
/// server cannot have acted on it: a `Connect` failure, or a timeout while
/// waiting for a connection slot or connecting. Such a request may be sent
/// again even when it is not idempotent.
///
/// ```mbt check
/// test {
///   assert_true(@http.Connect("refused").is_unsent())
///   assert_true(@http.Timeout(phase=Dial, ms=1000).is_unsent())
///   assert_false(@http.Timeout(phase=Head, ms=1000).is_unsent())
///   assert_false(@http.Network(phase=Write, message="reset").is_unsent())
/// }
/// ```
pub fn HttpError::is_unsent(self : HttpError) -> Bool {
  match self {
    Connect(_) | Timeout(phase=Pool | Dial, ..) => true
    Timeout(..) | Network(..) | Protocol(_) => false
  }
}

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
