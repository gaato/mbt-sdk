///|
test "presence option conversion and map preserve all three states" {
  for
    (value, option, absent) in (
      [
        (@json.Absent, None, true),
        (@json.Null, None, false),
        (@json.Value(7), Some(7), false),
      ] : Array[(@json.Presence[Int], Int?, Bool)]) {
    assert_eq(value.to_option(), option)
    assert_eq(value.is_absent(), absent)
    let mut calls = 0
    let mapped = value.map(n => {
      calls += 1
      n.to_string()
    })
    assert_eq(mapped.to_option(), option.map(n => n.to_string()))
    assert_eq(mapped.is_absent(), absent)
    assert_eq(calls, if option is Some(_) { 1 } else { 0 })
  }
  assert_eq(@json.Presence::from_option((None : Int?)), @json.Absent)
  assert_eq(@json.Presence::from_option(Some(7)), @json.Value(7))
}

///|
test "builder ordering replacement omission and snapshots" {
  let builder = @json.ObjBuilder::new()
  assert_eq(builder.build(), {})
  let same = builder
    .field("first", 1)
    .field("second", "two")
    .field("first", 3)
    .opt("skip", (None : Int?))
    .opt("optional", Some(false))
    .presence("absent", (@json.Absent : @json.Presence[Int]))
    .presence("null", (@json.Null : @json.Presence[Int]))
    .presence("value", @json.Value(4))
  let snapshot = same.build()
  assert_eq(
    snapshot.stringify(),
    "{\"first\":3,\"second\":\"two\",\"optional\":false,\"null\":null,\"value\":4}",
  )
  // Omission does not delete or overwrite a field that already exists.
  ignore(
    builder
    .opt("first", (None : Int?))
    .presence("second", (@json.Absent : @json.Presence[String])),
  )
  assert_eq(builder.build(), snapshot)
  ignore(
    builder
    .field("first", 9)
    .presence("second", (@json.Null : @json.Presence[String])),
  )
  assert_eq(
    builder.build().stringify(),
    "{\"first\":9,\"second\":null,\"optional\":false,\"null\":null,\"value\":4}",
  )
  assert_eq(
    snapshot.stringify(),
    "{\"first\":3,\"second\":\"two\",\"optional\":false,\"null\":null,\"value\":4}",
  )
}

///|
fn expect_decode_error(
  f : () -> Unit raise @core_json.JsonDecodeError,
  expected : @core_json.JsonPath,
) -> Unit raise {
  try f() catch {
    @core_json.JsonDecodeError((path, message)) => {
      assert_eq(path, expected)
      assert_true(message.length() > 0)
    }
  } noraise {
    _ => fail("expected a decode error")
  }
}

///|
test "field variants missing null wrong type and success with keyed error paths" {
  let path = root_path().add_key("parent").add_index(2)
  let obj = @json.expect_object(
    { "null": null, "bad": false, "ok": "yes" },
    path,
  )
  for key in ["missing", "null", "bad"] {
    expect_decode_error(
      () => {
        let _ : String = @json.field(obj, key, path)
      },
      path.add_key(key),
    )
  }
  assert_eq((@json.field(obj, "ok", path) : String), "yes")
  for key in ["missing", "null"] {
    assert_eq((@json.opt_field(obj, key, path) : String?), None)
  }
  assert_eq((@json.opt_field(obj, "ok", path) : String?), Some("yes"))
  assert_eq(
    (@json.presence_field(obj, "missing", path) : @json.Presence[String]),
    @json.Absent,
  )
  assert_eq(
    (@json.presence_field(obj, "null", path) : @json.Presence[String]),
    @json.Null,
  )
  assert_eq(
    (@json.presence_field(obj, "ok", path) : @json.Presence[String]),
    @json.Value("yes"),
  )
  expect_decode_error(
    () => {
      let _ : String? = @json.opt_field(obj, "bad", path)
    },
    path.add_key("bad"),
  )
  expect_decode_error(
    () => {
      let _ : @json.Presence[String] = @json.presence_field(obj, "bad", path)
    },
    path.add_key("bad"),
  )
  // Required null is permitted if T itself accepts null.
  assert_eq((@json.field(obj, "null", path) : String?), None)
  for value in ([null, [], "no", 1, false] : Array[Json]) {
    expect_decode_error(() => ignore(@json.expect_object(value, path)), path)
  }
  assert_eq(@json.expect_object({}, path).length(), 0)
}

///|
test "open strings choose known or unknown exactly once and reject other types" {
  let path = root_path().add_key("kind")
  for
    (raw, expected) in [
      ("stop", "known"),
      ("new", "unknown:new"),
      ("", "unknown:"),
    ] {
    let mut known_calls = 0
    let mut unknown_calls = 0
    let result = @json.open_string(
      Json(raw),
      path,
      s => {
        known_calls += 1
        if s == "stop" {
          Some("known")
        } else {
          None
        }
      },
      s => {
        unknown_calls += 1
        "unknown:\{s}"
      },
    )
    assert_eq(result, expected)
    assert_eq(known_calls, 1)
    assert_eq(unknown_calls, if raw == "stop" { 0 } else { 1 })
  }
  for value in ([null, 1, 1.5, true, [], {}] : Array[Json]) {
    expect_decode_error(
      () => ignore(@json.open_string(value, path, _ => Some(1), _ => 2)),
      path,
    )
  }
}

///|
test "open integers preserve unknown values and reject fractions overflow and other types" {
  let path = root_path().add_key("code")
  for raw in [0, 1, -1, 2147483647, -2147483648] {
    let mut known_calls = 0
    let mut unknown_calls = 0
    let result = @json.open_int(
      Json(raw),
      path,
      n => {
        known_calls += 1
        if n == 1 {
          Some("known")
        } else {
          None
        }
      },
      n => {
        unknown_calls += 1
        "unknown:\{n}"
      },
    )
    assert_eq(result, if raw == 1 { "known" } else { "unknown:\{raw}" })
    assert_eq(known_calls, 1)
    assert_eq(unknown_calls, if raw == 1 { 0 } else { 1 })
  }
  for value in ([1.0, -0.0, 1.0e3] : Array[Json]) {
    assert_true(@json.open_int(value, path, _ => None, n => n) >= 0)
  }
  for
    value in (
      [null, "1", false, [], {}, 1.5, -1.5, 2147483648, -2147483649, 1.0e100] :
      Array[Json]) {
    let mut calls = 0
    expect_decode_error(
      () => {
        ignore(
          @json.open_int(
            value,
            path,
            _ => {
              calls += 1
              Some(1)
            },
            _ => {
              calls += 1
              2
            },
          ),
        )
      },
      path,
    )
    assert_eq(calls, 0)
  }
}

///|
enum Kind {
  Stop
  Unknown(String)
} derive(Eq, Debug)

///|
struct Example {
  name : String
  count : Int?
  note : @json.Presence[String]
  kind : Kind
} derive(Eq, Debug)

///|
impl ToJson for Example with fn to_json(self) {
  @json.ObjBuilder::new()
  .field("name", self.name)
  .opt("count", self.count)
  .presence("note", self.note)
  .field(
    "kind",
    match self.kind {
      Stop => "stop"
      Unknown(raw) => raw
    },
  )
  .build()
}

///|
// Core exposes JsonPath abstractly; receive its root through FromJson.
struct DecodePath(@core_json.JsonPath)

///|
impl @core_json.FromJson for DecodePath with fn from_json(_value, path) {
  DecodePath(path)
}

///|
fn root_path() -> @core_json.JsonPath raise @core_json.JsonDecodeError {
  let decoded : DecodePath = @core_json.from_json(null)
  decoded.0
}

///|
impl @core_json.FromJson for Example with fn from_json(value, path) {
  let obj = @json.expect_object(value, path)
  let raw : Json = @json.field(obj, "kind", path)
  {
    name: @json.field(obj, "name", path),
    count: @json.opt_field(obj, "count", path),
    note: @json.presence_field(obj, "note", path),
    kind: @json.open_string(
      raw,
      path.add_key("kind"),
      s => if s == "stop" { Some(Stop) } else { None },
      s => Unknown(s),
    ),
  }
}

///|
test "small struct round trips optional presence and open enum through JSON text" {
  for count in [None, Some(3)] {
    for note in [@json.Absent, @json.Null, @json.Value("hello")] {
      for kind in [Stop, Unknown("future")] {
        let original : Example = { name: "sample", count, note, kind, }
        let text = ToJson::to_json(original).stringify()
        let decoded : Example = @core_json.from_json(@core_json.parse(text))
        assert_eq(decoded, original)
      }
    }
  }
}
