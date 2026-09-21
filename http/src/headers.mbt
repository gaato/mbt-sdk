///|
/// Mutable, ordered header pairs with ASCII lowercase names.
/// Equality compares normalized pairs, including their order.
///
/// ```mbt check
/// test {
///   let headers = @http.Headers::from_array([("Accept", "text/plain")])
///   assert_eq(headers.get("ACCEPT"), Some("text/plain"))
/// }
/// ```
pub struct Headers {
  priv mut pairs : Array[(String, String)]
} derive(Eq, Debug)

///|
/// Explicit equality methods for normalized, ordered pairs.
pub extend Headers with Eq::{equal, not_equal}

///|
/// Debug representation of the header pairs.
pub extend Headers with @debug.Debug::{to_repr}

///|
/// Creates an empty header collection.
pub fn Headers::new() -> Headers {
  { pairs: [], }
}

///|
/// Copies pairs in their original order and normalizes their names.
pub fn Headers::from_array(pairs : Array[(String, String)]) -> Headers {
  { pairs: pairs.map(pair => (pair.0.to_lower(), pair.1)), }
}

///|
/// Replaces all values for a name at its first position, or appends a new name.
pub fn Headers::set(self : Headers, name : String, value : String) -> Unit {
  let name = name.to_lower()
  let pairs = []
  let mut found = false
  for pair in self.pairs {
    if pair.0 == name {
      if !found {
        pairs.push((name, value))
        found = true
      }
    } else {
      pairs.push(pair)
    }
  }
  if !found {
    pairs.push((name, value))
  }
  self.pairs = pairs
}

///|
/// Appends one pair, retaining all existing values.
pub fn Headers::append(self : Headers, name : String, value : String) -> Unit {
  self.pairs.push((name.to_lower(), value))
}

///|
/// Returns the first value for a name, ignoring ASCII case.
pub fn Headers::get(self : Headers, name : String) -> String? {
  let name = name.to_lower()
  for (key, value) in self.pairs {
    if key == name {
      return Some(value)
    }
  }
  None
}

///|
/// Returns a fresh array containing every matching value in insertion order.
pub fn Headers::get_all(self : Headers, name : String) -> Array[String] {
  let name = name.to_lower()
  self.pairs.filter_map(pair => if pair.0 == name { Some(pair.1) } else { None })
}

///|
/// Removes all pairs for a name, ignoring ASCII case.
pub fn Headers::remove(self : Headers, name : String) -> Unit {
  let name = name.to_lower()
  self.pairs = self.pairs.filter(pair => pair.0 != name)
}

///|
/// Reports whether at least one value exists for a name.
pub fn Headers::contains(self : Headers, name : String) -> Bool {
  self.get(name) is Some(_)
}

///|
/// Iterates over a snapshot of normalized pairs in insertion order.
pub fn Headers::iter(self : Headers) -> Iter[(String, String)] {
  self.pairs.copy().iter()
}

///|
/// Visits a snapshot of normalized pairs in insertion order.
pub fn Headers::each(
  self : Headers,
  f : (String, String) -> Unit raise?,
) -> Unit raise? {
  for (name, value) in self.iter() {
    f(name, value)
  }
}

///|
/// Returns the number of pairs, counting repeated names separately.
pub fn Headers::length(self : Headers) -> Int {
  self.pairs.length()
}

///|
fn Headers::copy(self : Headers) -> Headers {
  { pairs: self.pairs.copy(), }
}
