///|
/// Distinguishes an omitted property from null and a present value.
///
/// ```mbt check
/// test {
///   let value = @json.Presence::from_option(Some(3))
///   assert_eq(value.map(n => n + 1).to_option(), Some(4))
///   assert_false(value.is_absent())
/// }
/// ```
pub(all) enum Presence[T] {
  Absent
  Null
  Value(T)
} derive(Eq, Debug)

///|
/// Compares presence and, for Value, the contained value.
pub extend Presence with Eq::{equal, not_equal}

///|
/// Formats the presence state and its value for debugging.
pub extend Presence with @debug.Debug::{to_repr}

///|
/// Collapses both omission and null to None.
pub fn[T] Presence::to_option(self : Presence[T]) -> T? {
  match self {
    Value(value) => Some(value)
    Absent | Null => None
  }
}

///|
/// Represents None as omission.
pub fn[T] Presence::from_option(value : T?) -> Presence[T] {
  match value {
    Some(value) => Value(value)
    None => Absent
  }
}

///|
/// Transforms only a present value, preserving omission and null.
pub fn[T, U] Presence::map(self : Presence[T], f : (T) -> U) -> Presence[U] {
  match self {
    Value(value) => Value(f(value))
    Absent => Absent
    Null => Null
  }
}

///|
/// Reports omission, as distinct from an explicit null.
pub fn[T] Presence::is_absent(self : Presence[T]) -> Bool {
  self is Absent
}
