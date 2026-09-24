///|
struct CompileClock {}

///|
impl @clock.Clock for CompileClock with fn sleep(_self, _milliseconds) {
  ()
}

///|
impl @clock.Clock for CompileClock with fn now_unix_ms(_self) {
  0L
}

///|
struct CompileTransport {}

///|
impl @http.Transport for CompileTransport with fn send(_self, _request) {
  { status: 204, headers: @http.Headers::new(), body: b"", }
}

///|
impl @http.Transport for CompileTransport with fn send_stream(_self, _request) {
  raise @http.HttpError::Protocol("compile only")
}

///|
async fn async_api_scenario() -> Unit {
  let clock : &@clock.Clock = CompileClock::{ }
  let transport : &@http.Transport = CompileTransport::{ }
  let limiter = @runtime.WindowLimiter::new(
    clock,
    @runtime.rate_limit_headers(
      remaining="remaining",
      reset_after_seconds="reset-after",
    ),
  )
  let client = @runtime.Client::new(
    transport,
    clock,
    base_url="https://example.test",
    retry=@runtime.RetryPolicy::none(),
    limiter~,
    observer=_attempt => (),
  )
  ignore(client.send(@http.Request::get("/"), global_exempt=true))
  ignore(client.send_json(@http.Request::get("/")))
  ignore(client.send_stream(@http.Request::get("/"))) catch {
    _ => ()
  }
  let paginator : @runtime.Paginator[Int, @runtime.SdkError] = @runtime.Paginator::with_cursor(_cursor => @runtime.Page::{
      items: [1],
      next: None,
    },
  )
  ignore(paginator.next_page())
  paginator.each(_ => ())
  ignore(paginator.collect(max=1))
}

///|
test "async public API compiles without importing an async runtime" {
  let _ : async () -> Unit = async_api_scenario
}
