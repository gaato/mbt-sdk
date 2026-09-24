///|
/// One decoded page and its optional cursor for the following page, for
/// `Paginator::with_cursor`.
pub(all) struct Page[T] {
  items : Array[T]
  next : String?
}

///|
/// A stateful async paginator.
///
/// `E` is the error the fetch raises, so an SDK exposes its own error type
/// through the paginator instead of `SdkError`.
pub struct Paginator[T, E] {
  // A struct type parameter cannot carry an `Error` bound, so the fetch is
  // stored with its failure as a value and re-raised by the methods.
  priv fetch : async () -> Result[Array[T]?, E] noraise
  priv mut done : Bool
  priv mut pending : Array[T]?
}

///|
/// Creates a paginator over a fetch that owns its own cursor.
///
/// `fetch` returns the next page, or `None` once the sequence has ended; an
/// empty page ends it as well. The fetch keeps whatever cursor the API uses
/// (a snowflake, a timestamp, a URL) and must advance it only after a page
/// has arrived, so that a fetch that raised is asked for the same page again.
/// For an API whose cursor is one string, `with_cursor` keeps that state here.
pub fn[T, E : Error] Paginator::new(
  fetch : async () -> Array[T]? raise E,
) -> Paginator[T, E] {
  {
    fetch: () => Ok(fetch()) catch { error => Err(error) },
    done: false,
    pending: None,
  }
}

///|
/// Creates a paginator over a string cursor. The first fetch receives `None`;
/// each page names the cursor of the following one, and a page without a
/// cursor is the last. A fetch that raised leaves the cursor unchanged.
pub fn[T, E : Error] Paginator::with_cursor(
  fetch : async (String?) -> Page[T] raise E,
) -> Paginator[T, E] {
  let cursor : Ref[String?] = Ref(None)
  let started = Ref(false)
  let finished = Ref(false)
  Paginator::new(() => {
    if finished.val {
      return None
    }
    let page = fetch(if started.val { cursor.val } else { None })
    started.val = true
    cursor.val = page.next
    finished.val = page.next is None
    Some(page.items)
  })
}

///|
/// Fetches the next non-empty page, or `None` once the sequence has ended.
/// Items that a previous `collect` did not use come back first.
pub async fn[T, E : Error] Paginator::next_page(
  self : Paginator[T, E],
) -> Array[T]? raise E {
  if self.pending is Some(items) {
    self.pending = None
    return Some(items)
  }
  if self.done {
    return None
  }
  let page = match (self.fetch)() {
    Ok(page) => page
    Err(error) => raise error
  }
  match page {
    Some(items) if !items.is_empty() => Some(items)
    _ => {
      self.done = true
      None
    }
  }
}

///|
/// Visits every remaining item in page order.
pub async fn[T, E : Error] Paginator::each(
  self : Paginator[T, E],
  f : async (T) -> Unit raise E,
) -> Unit raise E {
  for ;; {
    guard self.next_page() is Some(items) else { return }
    for item in items {
      f(item)
    }
  }
}

///|
/// Collects at most `max` remaining items. The unused rest of the last page
/// is kept for the next call, so nothing fetched is lost. A non-positive
/// maximum performs no requests and returns an empty array.
pub async fn[T, E : Error] Paginator::collect(
  self : Paginator[T, E],
  max~ : Int,
) -> Array[T] raise E {
  let result = []
  if max <= 0 {
    return result
  }
  for ; result.length() < max; {
    guard self.next_page() is Some(items) else { break }
    for index, item in items {
      result.push(item)
      if result.length() == max {
        if index + 1 < items.length() {
          self.pending = Some(items[index + 1:].to_owned())
        }
        break
      }
    }
  }
  result
}
