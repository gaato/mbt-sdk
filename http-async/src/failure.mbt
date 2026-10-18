///|
/// The `HttpError` for `error`, raised while the transport was in `phase`.
/// An `HttpError` passes through, so a step may raise its own. Otherwise a
/// failure before the connection is made is `Connect`, since nothing was
/// sent, and one after it is `Network` in the phase the platform can see
/// (`reported_phase`), unless the platform recognises a malformed message
/// (`is_malformed`), which is `Protocol`.
fn failure(phase : @http.Phase, error : Error) -> @http.HttpError {
  match error {
    @http.HttpError::Connect(message) => Connect(message)
    @http.HttpError::Timeout(phase~, ms~) => Timeout(phase~, ms~)
    @http.HttpError::Network(phase~, message~) => Network(phase~, message~)
    @http.HttpError::Protocol(message) => Protocol(message)
    @ahttp.URIParseError::InvalidFormat => Protocol("invalid URL")
    @ahttp.URIParseError::UnsupportedProtocol(protocol) =>
      Protocol("unsupported protocol: " + protocol)
    _ if is_malformed(error) => Protocol(error.to_string())
    _ =>
      match phase {
        Pool | Dial => Connect(error.to_string())
        Write | Head | Body | Unknown =>
          Network(phase=reported_phase(phase), message=error.to_string())
      }
  }
}
