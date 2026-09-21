///|
/// One decoded page and its optional cursor for the following page.
pub(all) struct Page[T] {
  items : Array[T]
  next : String?
}

///|
/// A stateful async cursor paginator.
pub struct Paginator[T] {
  priv fetch : async (String?) -> Page[T] raise SdkError
  priv mut next : String?
  priv mut started : Bool
  priv mut done : Bool
}

///|
/// Creates a paginator whose first fetch receives `None`.
pub fn[T] Paginator::new(
  fetch : async (String?) -> Page[T] raise SdkError,
) -> Paginator[T] {
  { fetch, next: None, started: false, done: false, }
}

///|
/// Fetches the next page. A failed fetch leaves the cursor unchanged.
pub async fn[T] Paginator::next_page(
  self : Paginator[T],
) -> Array[T]? raise SdkError {
  if self.done {
    return None
  }
  let cursor = if self.started { self.next } else { None }
  let page = (self.fetch)(cursor)
  self.started = true
  self.next = page.next
  self.done = page.next is None
  Some(page.items)
}

///|
/// Visits every remaining item in page order.
pub async fn[T] Paginator::each(
  self : Paginator[T],
  f : async (T) -> Unit raise SdkError,
) -> Unit raise SdkError {
  for ;; {
    guard self.next_page() is Some(items) else { return }
    for item in items {
      f(item)
    }
  }
}

///|
/// Collects at most `max` remaining items, discarding the unused page suffix.
pub async fn[T] Paginator::collect(
  self : Paginator[T],
  max~ : Int,
) -> Array[T] raise SdkError {
  let result = []
  if max <= 0 {
    return result
  }
  for ; result.length() < max; {
    guard self.next_page() is Some(items) else { break }
    for item in items {
      if result.length() >= max {
        break
      }
      result.push(item)
    }
  }
  result
}
