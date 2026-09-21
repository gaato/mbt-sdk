///|
fn expect_error(
  f : () -> Unit raise @multipart.MultipartError,
  expected : String,
) -> Unit raise {
  try f() catch {
    @multipart.InvalidBoundary(value) =>
      assert_eq(expected, "InvalidBoundary:" + value)
    @multipart.BoundaryCollision => assert_eq(expected, "BoundaryCollision")
    @multipart.InvalidHeaderValue(value) =>
      assert_eq(expected, "InvalidHeaderValue:" + value)
  } noraise {
    _ => fail("expected multipart error")
  }
}

///|
test "text file json several and zero parts are byte exact" {
  let (_, text) = @multipart.encode(
    [@multipart.Part::text("message", "hello")],
    "B",
  )
  assert_eq(
    text, b"--B\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\nhello\r\n--B--\r\n",
  )
  let (_, file) = @multipart.encode(
    [
      @multipart.Part::file(
        "upload", "a.bin", "application/octet-stream", b"\x00\xFF",
      ),
    ],
    "B",
  )
  assert_eq(
    file, b"--B\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n\x00\xFF\r\n--B--\r\n",
  )
  let (_, json) = @multipart.encode(
    [@multipart.Part::json("metadata", { "name": "moon", "ok": true })],
    "B",
  )
  assert_eq(
    json, b"--B\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{\"name\":\"moon\",\"ok\":true}\r\n--B--\r\n",
  )
  let (_, several) = @multipart.encode(
    [@multipart.Part::text("a", "one"), @multipart.Part::text("b", "two")],
    "B",
  )
  assert_eq(
    several, b"--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\none\r\n--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\ntwo\r\n--B--\r\n",
  )
  let (_, zero) = @multipart.encode([], "B")
  assert_eq(zero, b"--B--\r\n")
}

///|
test "parameters escape quote CR LF and retain UTF-8" {
  let (_, body) = @multipart.encode(
    [@multipart.Part::file("a\"\r\nb", "日本\"\r\n.txt", "text/plain", b"ok")],
    "B",
  )
  assert_eq(
    body,
    @utf8.encode(
      "--B\r\nContent-Disposition: form-data; name=\"a%22%0D%0Ab\"; filename=\"日本%22%0D%0A.txt\"\r\nContent-Type: text/plain\r\n\r\nok\r\n--B--\r\n",
    ),
  )
}

///|
test "content type rejects CR and LF" {
  for value in ["text/plain\rbad", "text/plain\nbad", "x\r\ny"] {
    expect_error(
      () => {
        ignore(
          @multipart.encode([@multipart.Part::file("f", "x", value, b"")], "B"),
        )
      },
      "InvalidHeaderValue:" + value,
    )
  }
}

///|
test "boundary validation and header quoting" {
  for
    boundary in [
      "", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bad ", "bad[",
    ] {
    expect_error(
      () => ignore(@multipart.encode([], boundary)),
      "InvalidBoundary:" + boundary,
    )
  }
  assert_eq(
    @multipart.encode([], "a:b").0,
    "multipart/form-data; boundary=\"a:b\"",
  )
  assert_eq(
    @multipart.encode([], "a b").0,
    "multipart/form-data; boundary=\"a b\"",
  )
  assert_eq(
    @multipart.encode([], "a'b+_.-").0,
    "multipart/form-data; boundary=a'b+_.-",
  )
  assert_eq(
    @multipart.encode(
      [],
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ).0,
    "multipart/form-data; boundary=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
}

///|
test "boundary collision detects delimiter-shaped bytes only" {
  for body in [b"prefix\r\n--BOUNDARYsuffix", b"--BOUNDARY at start"] {
    expect_error(
      () => {
        ignore(
          @multipart.encode(
            [@multipart.Part::file("f", "x", "x", body)],
            "BOUNDARY",
          ),
        )
      },
      "BoundaryCollision",
    )
  }
  let (_, body) = @multipart.encode(
    [@multipart.Part::file("f", "x", "x", b"plain BOUNDARY content")],
    "BOUNDARY",
  )
  assert_true(body.find(b"plain BOUNDARY content"[:]) is Some(_))
}

///|
test "make_boundary is fixed deterministic and clamps random values" {
  let values = [
    0.0,
    1.0 / 36.0,
    0.5,
    35.0 / 36.0,
    0.9999999999999999,
    -1.0,
    1.0,
    2.0,
    0.0 / 0.0,
  ]
  let mut index = 0
  let boundary = @multipart.make_boundary(() => {
    let value = values[index % values.length()]
    index += 1
    value
  })
  assert_eq(boundary.length(), 40)
  assert_eq(boundary, "mbt-sdk-01izz0zz001izz0zz001izz0zz001izz")
  assert_true(boundary.has_prefix("mbt-sdk-"))
  assert_true(
    boundary[8:].iter().all(c => c.is_ascii_digit() || (c >= 'a' && c <= 'z')),
  )
}

///|
test "apply replaces content type preserves headers and input" {
  let original = @http.Request::post("/upload")
    .header("Content-Type", "old/one")
    .header("content-type", "old/two")
    .header("x-keep", "yes")
    .body_bytes(b"old body")
  let result = @multipart.apply(
    original,
    [@multipart.Part::text("a", "new")],
    "B",
  )
  assert_eq(result.headers.get_all("content-type"), [
    "multipart/form-data; boundary=B",
  ])
  assert_eq(result.headers.get("x-keep"), Some("yes"))
  assert_eq(original.headers.get_all("content-type"), ["old/one", "old/two"])
  assert_eq(original.headers.get("x-keep"), Some("yes"))
  assert_eq(original.body, b"old body")
  assert_true(result.body != original.body)
}

///|
test "all byte values round trip without transformation" {
  let bytes = Bytes::makei(256, i => i.to_byte())
  let (_, encoded) = @multipart.encode(
    [@multipart.Part::file("binary", "all.bin", "x/binary", bytes)],
    "B",
  )
  let prefix = b"--B\r\nContent-Disposition: form-data; name=\"binary\"; filename=\"all.bin\"\r\nContent-Type: x/binary\r\n\r\n"
  let suffix = b"\r\n--B--\r\n"
  assert_eq(
    encoded[prefix.length():encoded.length() - suffix.length()],
    bytes[:],
  )
}
