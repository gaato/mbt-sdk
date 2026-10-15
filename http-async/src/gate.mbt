///|
/// An admission gate backed by a cancellable async semaphore.
pub struct SemaphoreGate {
  priv semaphore : @semaphore.Semaphore
}

///|
/// Creates a gate with a positive number of permits (one by default).
pub fn SemaphoreGate::new(permits~ : Int32 = 1) -> SemaphoreGate {
  { semaphore: @semaphore.Semaphore(permits), }
}

///|
/// Explicit gate methods backed by the semaphore.
pub extend SemaphoreGate with @sync.Gate::{acquire, release}

///|
/// Waits for a permit, allowing runtime cancellation while queued.
pub impl @sync.Gate for SemaphoreGate with fn acquire(self) {
  self.semaphore.acquire()
}

///|
/// Returns one acquired permit.
pub impl @sync.Gate for SemaphoreGate with fn release(self) {
  self.semaphore.release()
}
