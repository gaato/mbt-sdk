///|
pub using @fake {type FakeClock}

///|
/// Buffered fixtures retained from the SDK behaviour corpus.
pub(all) struct Buffered {
  status : Int32
  headers : @model.Headers
  body : Bytes
}

///|
/// Test-only suffix expectations over mttp's strict backend stub.
pub struct FakeBackend {
  priv stub : @testing.BackendStub
  priv requests : Array[@model.Request]
  priv closed_streams : Ref[Int32]
}

///|
pub fn FakeBackend::new() -> FakeBackend {
  { stub: @testing.BackendStub::new(), requests: [], closed_streams: Ref(0), }
}

///|
pub fn FakeBackend::expect(
  self : FakeBackend,
  meth : String,
  suffix : String,
  response : Buffered,
) -> Unit {
  self.stub.expect(
    request => {
      request.meth.to_string().to_lower() == meth.to_lower() &&
      request.url.has_suffix(suffix)
    },
    @testing.Canned::bytes(
      response.status,
      headers=response.headers,
      body=response.body,
    ),
  )
  |> ignore
}

///|
pub fn FakeBackend::expect_stream(
  self : FakeBackend,
  meth : String,
  suffix : String,
  head : @model.ResponseHead,
  chunks : Array[Bytes],
) -> Unit {
  self.stub.expect(
    request => {
      request.meth.to_string().to_lower() == meth.to_lower() &&
      request.url.has_suffix(suffix)
    },
    @testing.Factory((_, _) => {
      let stream = Chunks::{
        chunks: chunks.copy(),
        index: 0,
        closed: false,
        counter: self.closed_streams,
      }
      @model.Response::new(
        head.status,
        headers=head.headers,
        body=Stream(@model.StreamBody::new(stream)),
      )
    }),
  )
  |> ignore
}

///|
pub fn FakeBackend::expect_error(
  self : FakeBackend,
  meth : String,
  suffix : String,
  error : @model.TransportError,
) -> Unit {
  self.stub.expect(
    request => {
      request.meth.to_string().to_lower() == meth.to_lower() &&
      request.url.has_suffix(suffix)
    },
    @testing.Failure(error),
  )
  |> ignore
}

///|
pub fn FakeBackend::sent(self : FakeBackend) -> Array[@model.Request] {
  self.requests.copy()
}

///|
pub fn FakeBackend::streams_closed(self : FakeBackend) -> Int32 {
  self.closed_streams.val
}

///|
pub fn FakeBackend::assert_complete(self : FakeBackend) -> Unit raise {
  self.stub.verify()
}

///|
pub extend FakeBackend with @client.Backend::{send, close}

///|
pub impl @client.Backend for FakeBackend with fn send(self, request, options) {
  self.requests.push(request)
  self.stub.send(request, options)
}

///|
pub impl @client.Backend for FakeBackend with fn close(self) {
  self.stub.close()
}

///|
priv struct Chunks {
  chunks : Array[Bytes]
  mut index : Int32
  mut closed : Bool
  counter : Ref[Int32]
}

///|
impl @model.BodyStream for Chunks with fn read_some(self) {
  if self.closed {
    return None
  }
  let chunk = self.chunks.get(self.index)
  if chunk is Some(_) {
    self.index += 1
  }
  chunk
}

///|
impl @model.BodyStream for Chunks with fn close(self) {
  if !self.closed {
    self.closed = true
    self.counter.val += 1
  }
}
