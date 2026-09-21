///|
/// Mutable object builder retaining each key's original insertion position.
///
/// ```mbt check
/// test {
///   let builder = @json.ObjBuilder::new()
///     .field("name", "sample")
///     .opt("count", (None : Int?))
///     .presence("note", (@json.Null : @json.Presence[String]))
///   assert_eq(builder.build(), { "name": "sample", "note": null })
/// }
/// ```
pub struct ObjBuilder {
  priv fields : Map[String, Json]
}

///|
/// Creates an empty builder.
pub fn ObjBuilder::new() -> ObjBuilder {
  { fields: {}, }
}

///|
/// Writes a field, replacing any previous value at its original position.
pub fn[T : ToJson] ObjBuilder::field(
  self : ObjBuilder,
  key : String,
  value : T,
) -> ObjBuilder {
  self.fields[key] = value.to_json()
  self
}

///|
/// Writes Some values and leaves the builder unchanged for None.
pub fn[T : ToJson] ObjBuilder::opt(
  self : ObjBuilder,
  key : String,
  value : T?,
) -> ObjBuilder {
  if value is Some(value) {
    self.fields[key] = value.to_json()
  }
  self
}

///|
/// Omits Absent, writes null for Null, and encodes Value.
pub fn[T : ToJson] ObjBuilder::presence(
  self : ObjBuilder,
  key : String,
  value : Presence[T],
) -> ObjBuilder {
  match value {
    Absent => ()
    Null => self.fields[key] = Json::null()
    Value(value) => self.fields[key] = value.to_json()
  }
  self
}

///|
/// Returns a snapshot of the current fields, preserving insertion order.
pub fn ObjBuilder::build(self : ObjBuilder) -> Json {
  Json::object(self.fields.copy())
}
