///|
// Compile-only: gaato/http cannot run async tests, so http-async tests the
// real implementation. This checks that the trait can be implemented and
// used as a trait object.
struct Expired {}

///|
impl @sync.Timer for Expired with fn within(_, _, _) {
  false
}

///|
test "a timer can be implemented outside the package" {
  let timer : &@sync.Timer = Expired::{ }
  ignore(timer)
}
