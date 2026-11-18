///|
/// All wire fixtures in this file are constructed from the vendored Gemini
/// v1beta Discovery schema (revision 20261113), 2026-11-16. Upload headers follow
/// https://ai.google.dev/gemini-api/docs/files (read 2026-11-16).
fn response(value : Json, status~ : Int32 = 200) -> @http.Response {
  @http.Response::new(status, body=Bytes(@utf8.encode(value.stringify())))
}

///|
fn prompt() -> @gen.GenerateContentRequest {
  @gen.GenerateContentRequest::new(contents=[
    @gen.Content::new(role="user", parts=[
      @gen.Part::Text(@gen.PartText::new(text="Hello")),
    ]),
  ])
}

///|
test "Gemini generate content typed multimodal oneof and signatures" {
  let seen : Ref[@http.Request?] = Ref(None)
  let backend = @client.from_fn((request, _) => {
    seen.val = Some(request)
    response({
      "candidates": [
        {
          "content": {
            "role": "model",
            "parts": [
              { "text": "Hello!", "thought": true, "thoughtSignature": "c2ln" },
            ],
          },
          "finishReason": "STOP",
        },
      ],
      "usageMetadata": { "totalTokenCount": 9 },
    })
  })
  let sdk = @gemini.Gemini::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiKey("offline-key"),
  )
  let result = @driver.run_sync(() => {
    sdk.generate_content(model="test-model", prompt())
  })
  guard result is Ok(reply) else { fail("generate failed") }
  assert_eq(reply.usage_metadata.unwrap().total_token_count, Some(9))
  let part = reply.candidates.unwrap()[0].content.unwrap().parts.unwrap()[0]
  guard part is Text(text) else { fail("expected text") }
  assert_eq(text.thought_signature, Some("c2ln"))
  assert_eq(text.thought, Some(true))
  let request = seen.val.unwrap()
  assert_eq(
    request.url,
    "https://generativelanguage.googleapis.com/v1beta/models/test-model:generateContent",
  )
  assert_eq(request.headers.get("x-goog-api-key"), Some("offline-key"))
  guard request.body is Bytes(bytes) else { fail("expected buffered JSON") }
  let json = @json.parse(@utf8.decode(bytes))
  assert_eq(json, Json(prompt()))
  let video : @gen.Part = FileData(
    @gen.PartFileData::new(
      file_data=@gen.FileData::new(
        file_uri="https://example.invalid/movie",
        mime_type="video/mp4",
      ),
      thought_signature="c2ln",
      video_metadata=@gen.VideoMetadata::new(start_offset="1s"),
      part_metadata={ "source": "offline" },
    ),
  )
  let decoded : @gen.Part = @json.from_json(Json(video))
  assert_eq(Json(decoded), Json(video))
  let invalids : Array[Json] = [
    {},
    { "text": "x", "inlineData": {} },
    { "text": Json::null() },
  ]
  for invalid in invalids {
    let decoded : @gen.Part? = Some(@json.from_json(invalid)) catch {
      _ => None
    }
    assert_true(decoded is None)
  }
}

///|
test "Gemini count tokens embedding and batch embedding" {
  let seen : Array[String] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.url)
    if request.url.has_suffix(":countTokens") {
      response({ "totalTokens": 12 })
    } else if request.url.has_suffix(":batchEmbedContents") {
      response({ "embeddings": [{ "values": [0.1, 0.2] }] })
    } else {
      response({ "embedding": { "values": [0.1, 0.2] } })
    }
  })
  let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
  @driver.run_sync(() => {
    guard sdk.count_tokens(
        model="test",
        @gen.CountTokensRequest::new(contents=prompt().contents.unwrap()),
      )
      is Ok(tokens) else {
      fail("tokens")
    }
    assert_eq(tokens.total_tokens, Some(12))
    let body = @gen.EmbedContentRequest::new(
      content=prompt().contents.unwrap()[0],
    )
    guard sdk.embed_content(model="test", body) is Ok(embedding) else {
      fail("embedding")
    }
    assert_eq(embedding.embedding.unwrap().values, Some([0.1, 0.2]))
    guard sdk.batch_embed_contents(
        model="test",
        @gen.BatchEmbedContentsRequest::new(requests=[body]),
      )
      is Ok(batch) else {
      fail("batch")
    }
    assert_eq(batch.embeddings.unwrap().length(), 1)
  })
  assert_eq(seen.length(), 3)
}

///|
test "Gemini SSE several events typed stop and malformed event" {
  let events = b"data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a\"}]}}]}\n\ndata: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"b\"}]}}]}\n\ndata: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\ndata: bad-after-stop\n\n"
  let seen : Ref[String] = Ref("")
  let driver = @driver.Driver::new()
  let source = @sim.Feed::bytes(driver, [events, b"data: unread\n\n"])
  let backend = @client.from_fn((request, _) => {
    seen.val = request.url
    @http.Response::new(200, body=Stream(@http.StreamBody::new(source)))
  })
  let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
  let texts : Array[String] = []
  let result = driver.run(() => {
    sdk.stream_generate_content(
      model="test",
      prompt(),
      event => {
        if event.candidates.unwrap()[0].content.unwrap().parts.unwrap()[0]
          is Text(text) {
          texts.push(text.text)
        }
      },
      stop=event => event.candidates.unwrap()[0].finish_reason is Some(STOP),
    )
  })
  assert_true(result is Ok(_))
  assert_eq(texts, ["a", "b"])
  assert_eq(source.closes(), 1)
  assert_eq(source.reads(), 1)
  assert_true(seen.val.has_suffix(":streamGenerateContent?alt=sse"))
  let driver = @driver.Driver::new()
  let source = @sim.Feed::bytes(driver, [
    b"data: {not-json}\n\n", b"data: unread\n\n",
  ])
  let backend = @client.from_fn((_, _) => {
    @http.Response::new(200, body=Stream(@http.StreamBody::new(source)))
  })
  let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
  let called = Ref(false)
  let result = driver.run(() => {
    sdk.stream_generate_content(model="test", prompt(), _ => called.val = true)
  })
  assert_true(result is Err(Decode(_)))
  assert_false(called.val)
  assert_eq(source.closes(), 1)
  assert_eq(source.reads(), 1)
}

///|
test "Gemini resumable upload honors session URL finalize and metadata" {
  let seen : Array[@http.Request] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request)
    if seen.length() == 1 {
      @http.Response::new(
        200,
        headers=@http.Headers::of([
          (
            "X-Goog-Upload-URL", "https://generativelanguage.googleapis.com/upload/session?upload_id=offline",
          ),
        ]),
      )
    } else {
      response({
        "file": {
          "name": "files/offline",
          "uri": "https://example.invalid/file",
          "sizeBytes": "3",
          "state": "ACTIVE",
        },
      })
    }
  })
  let sdk = @gemini.Gemini::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiKey("offline-key"),
  )
  let result = @driver.run_sync(() => {
    sdk.upload_file(b"abc", mime_type="text/plain", display_name="sample")
  })
  guard result is Ok(uploaded) else { fail("upload") }
  assert_eq(uploaded.file.unwrap().size_bytes, Some(3L))
  assert_eq(seen.length(), 2)
  assert_eq(
    seen[0].url,
    "https://generativelanguage.googleapis.com/upload/v1beta/files",
  )
  assert_eq(seen[0].headers.get("X-Goog-Upload-Protocol"), Some("resumable"))
  assert_eq(seen[0].headers.get("X-Goog-Upload-Command"), Some("start"))
  assert_eq(
    seen[0].headers.get("X-Goog-Upload-Header-Content-Length"),
    Some("3"),
  )
  assert_eq(
    seen[0].headers.get("X-Goog-Upload-Header-Content-Type"),
    Some("text/plain"),
  )
  guard seen[0].body is Bytes(metadata) else { fail("metadata") }
  assert_eq(@json.parse(@utf8.decode(metadata)), {
    "file": { "mimeType": "text/plain", "displayName": "sample" },
  })
  assert_eq(
    seen[1].url,
    "https://generativelanguage.googleapis.com/upload/session?upload_id=offline",
  )
  assert_eq(
    seen[1].headers.get("X-Goog-Upload-Command"),
    Some("upload, finalize"),
  )
  assert_eq(seen[1].headers.get("X-Goog-Upload-Offset"), Some("0"))
  assert_eq(seen[1].headers.get("x-goog-api-key"), Some("offline-key"))
  guard seen[1].body is Bytes(bytes) else { fail("upload bytes") }
  assert_eq(bytes, b"abc")
}

///|
test "Gemini upload rejects missing malformed and cross-origin sessions and propagates errors" {
  for session in [None, Some("bad url"), Some("https://evil.invalid/upload")] {
    let count = Ref(0)
    let backend = @client.from_fn((_, _) => {
      count.val += 1
      @http.Response::new(
        200,
        headers=match session {
          Some(url) => @http.Headers::of([("X-Goog-Upload-URL", url)])
          None => @http.Headers::empty()
        },
      )
    })
    let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
    assert_true(
      @driver.run_sync(() => sdk.upload_file(b"x", mime_type="text/plain"))
      is Err(Decode(_)),
    )
    assert_eq(count.val, 1)
  }
  let count = Ref(0)
  let backend = @client.from_fn((_, _) => {
    count.val += 1
    response(
      {
        "error": {
          "code": 403,
          "message": "denied",
          "status": "PERMISSION_DENIED",
        },
      },
      status=403,
    )
  })
  let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
  assert_true(
    @driver.run_sync(() => sdk.upload_file(b"x", mime_type="text/plain"))
    is Err(Http(_)),
  )
  assert_eq(count.val, 1)
}

///|
test "Gemini files pagination get delete and models" {
  let urls : Array[String] = []
  let backend = @client.from_fn((request, _) => {
    urls.push(request.url)
    if request.url.contains("pageToken=") {
      response({ "files": [{ "name": "files/two" }] })
    } else if request.url.contains("/files?") {
      response({ "files": [{ "name": "files/one" }], "nextPageToken": "a b" })
    } else if request.meth == @http.Delete {
      response({})
    } else if request.url.has_suffix("/files/one") {
      response({ "name": "files/one" })
    } else if request.url.has_suffix("/models") {
      response({ "models": [{ "name": "models/test" }] })
    } else {
      response({ "name": "models/test" })
    }
  })
  let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
  @driver.run_sync(() => {
    let pages = sdk.list_files_pages(page_size=1)
    guard pages.next_page() is Ok(Some(first)) else { fail("first page") }
    guard pages.next_page() is Ok(Some(second)) else { fail("second page") }
    assert_eq(first[0].name, Some("files/one"))
    assert_eq(second[0].name, Some("files/two"))
    assert_true(pages.next_page() is Ok(None))
    assert_true(sdk.get_file(name=first[0].name.unwrap()) is Ok(_))
    let deleted : Result[Unit, @gemini.Failure] = sdk.delete_file(
      name=first[0].name.unwrap(),
    )
    assert_true(deleted is Ok(_))
    assert_true(sdk.list_models() is Ok(_))
    assert_true(sdk.get_model(name="models/test") is Ok(_))
  })
  assert_eq(urls.length(), 6)
  assert_true(urls[1].contains("pageToken=a%20b"))
  assert_true(urls[1].contains("pageSize=1"))
}

///|
test "Gemini cached contents CRUD and update mask" {
  let seen : Array[@http.Request] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request)
    if request.meth == @http.Delete {
      response({})
    } else if request.url.has_suffix("/cachedContents") &&
      request.meth == @http.Get {
      response({ "cachedContents": [{ "name": "cachedContents/test" }] })
    } else {
      response({ "name": "cachedContents/test", "ttl": "60s" })
    }
  })
  let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
  @driver.run_sync(() => {
    assert_true(
      sdk.create_cached_content(
        @gen.CachedContent::new(
          model="models/test",
          contents=prompt().contents.unwrap(),
          ttl="60s",
        ),
      )
      is Ok(_),
    )
    assert_true(sdk.get_cached_content(name="test") is Ok(_))
    assert_true(sdk.list_cached_contents() is Ok(_))
    assert_true(
      sdk.update_cached_content(
        name="test",
        @gen.CachedContent::new(ttl="120s"),
        update_mask="ttl",
      )
      is Ok(_),
    )
    assert_true(sdk.delete_cached_content(name="test") is Ok(_))
  })
  assert_eq(seen.length(), 5)
  assert_eq(seen[0].meth, @http.Post)
  assert_eq(seen[3].meth, @http.Patch)
  assert_true(seen[3].url.has_suffix("?updateMask=ttl"))
  assert_eq(seen[4].meth, @http.Delete)
}

///|
test "Gemini error bodies retry 503 honor Retry-After and never retry 429" {
  for
    (status, name, expected) in [
      (403, "PERMISSION_DENIED", 1),
      (429, "RESOURCE_EXHAUSTED", 1),
      (503, "UNAVAILABLE", 5),
    ] {
    let count = Ref(0)
    let clock = @sim.FakeClock::new()
    let body : Json = {
      "error": {
        "code": Json(status),
        "message": "offline",
        "status": Json(name),
        "details": [
          {
            "@type": "type.googleapis.com/google.rpc.RetryInfo",
            "retryDelay": "120s",
          },
        ],
      },
    }
    let backend = @client.from_fn((_, _) => {
      count.val += 1
      @http.Response::new(
        status,
        headers=@http.Headers::of([("Retry-After", "60")]),
        body=Bytes(@utf8.encode(body.stringify())),
      )
    })
    let sdk = @gemini.Gemini::new(backend, clock)
    guard @driver.run_sync(() => {
        sdk.count_tokens(model="test", @gen.CountTokensRequest::new())
      })
      is Err(Http(error)) else {
      fail("HTTP error")
    }
    assert_eq(error.head.status, status)
    assert_eq(error.operation, "models_count_tokens")
    guard error.typed is Some(GoogleError(value)) else { fail("typed error") }
    assert_eq(value.error.status, name)
    assert_eq(value.error.details.unwrap().length(), 1)
    assert_eq(count.val, expected)
    assert_eq(clock.slept().length(), expected - 1)
    if status == 503 {
      assert_eq(clock.slept(), [60000, 60000, 60000, 60000])
    }
  }
}

///|
test "Gemini Retry-After above sixty seconds stops without sleeping" {
  for delay in ["61", "120", "2147483647"] {
    let count = Ref(0)
    let clock = @sim.FakeClock::new()
    let backend = @client.from_fn((_, _) => {
      count.val += 1
      @http.Response::new(
        503,
        headers=@http.Headers::of([("Retry-After", delay)]),
        body=Bytes(
          b"{\"error\":{\"code\":503,\"message\":\"offline\",\"status\":\"UNAVAILABLE\"}}",
        ),
      )
    })
    let sdk = @gemini.Gemini::new(backend, clock)
    assert_true(
      @driver.run_sync(() => {
        sdk.count_tokens(model="test", @gen.CountTokensRequest::new())
      })
      is Err(Http(_)),
    )
    assert_eq(count.val, 1)
    assert_eq(clock.slept(), [])
  }
}

///|
test "Gemini accepts returned names and rejects path injection before sending" {
  let seen : Array[String] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.url)
    response({})
  })
  let sdk = @gemini.Gemini::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiKey("offline"),
  )
  @driver.run_sync(() => {
    for model in ["gemini-2.5-flash", "models/gemini-2.5-flash"] {
      assert_true(sdk.generate_content(model~, prompt()) is Ok(_))
      assert_true(sdk.get_model(name=model) is Ok(_))
    }
    for
      invalid in [
        "models/../cachedContents/x", "models/x?y", "models/x#y", "models/x&y", "models/x%2Fz",
        "models/x%2fz", "models/%252Fx", "models/x:verb", "x:verb", "", " ", "\t",
        "models/ ", "models/x/y", "models/.", "models/..", "models/x\\y", "models/x\ny",
      ] {
      assert_true(
        sdk.generate_content(model=invalid, prompt()) is Err(Validation(..)),
      )
      assert_true(sdk.get_model(name=invalid) is Err(Validation(..)))
    }
    assert_true(sdk.get_file(name="files/x/y") is Err(Validation(..)))
    assert_true(
      sdk.get_cached_content(name="cachedContents/x?y") is Err(Validation(..)),
    )
    assert_true(
      sdk.stream_generate_content(model="models/x:verb", prompt(), _ => {
        fail("must not receive")
      })
      is Err(Validation(..)),
    )
  })
  assert_eq(seen, [
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash", "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash",
  ])
}

///|
test "Gemini canonical generic calls infer the resource operation" {
  let seen : Array[String?] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.attributes.get(@client.operation_id))
    response(
      {
        "error": {
          "code": 403,
          "message": "offline",
          "status": "PERMISSION_DENIED",
        },
      },
      status=403,
    )
  })
  let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
  @driver.run_sync(() => {
    for
      (request, operation) in [
        (@gen.files_get_request("files/one"), "files_get"),
        (@gen.models_get_request("models/test"), "models_get"),
        (
          @gen.cached_contents_get_request("cachedContents/test"),
          "cached_contents_get",
        ),
      ] {
      guard sdk.send(request) is Err(Http(error)) else {
        fail("expected HTTP error")
      }
      assert_eq(error.operation, operation)
      assert_true(error.typed is Some(GoogleError(_)))
    }
  })
  assert_eq(seen, [
    Some("files_get"),
    Some("models_get"),
    Some("cached_contents_get"),
  ])
}

///|
test "Gemini empty protobuf deletes return Unit and close the response body" {
  for cache in [false, true] {
    for status in [200, 204] {
      let driver = @driver.Driver::new()
      let source = @sim.Feed::bytes(driver, [b"{", b"}"])
      let backend = @client.from_fn((_, _) => {
        @http.Response::new(status, body=Stream(@http.StreamBody::new(source)))
      })
      let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
      let result : Result[Unit, @gemini.Failure] = driver.run(() => {
        if cache {
          sdk.delete_cached_content(name="cachedContents/test")
        } else {
          sdk.delete_file(name="files/test")
        }
      })
      assert_true(result is Ok(_))
      assert_eq(source.closes(), 1)
      if status == 200 {
        assert_eq(source.reads(), 3)
      }
    }
  }
}

///|
test "Gemini omitted repeated fields end an empty list" {
  let backend = @client.from_fn((_, _) => response({}))
  let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
  @driver.run_sync(() => {
    assert_true(sdk.list_files_pages().next_page() is Ok(None))
    assert_true(sdk.list_models_pages().next_page() is Ok(None))
    assert_true(sdk.list_cached_contents_pages().next_page() is Ok(None))
  })
}

///|
test "Gemini retries unsent failures and strips API key on redirects" {
  let count = Ref(0)
  let backend = @client.from_fn((_, _) => {
    count.val += 1
    if count.val == 1 {
      raise @http.TransportError(kind=Connect, phase=Dial, detail="offline")
    }
    response({ "totalTokens": 1 })
  })
  let sdk = @gemini.Gemini::new(backend, @sim.FakeClock::new())
  assert_true(
    @driver.run_sync(() => {
      sdk.count_tokens(model="test", @gen.CountTokensRequest::new())
    })
    is Ok(_),
  )
  assert_eq(count.val, 2)
  let seen : Array[String?] = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request.headers.get("x-goog-api-key"))
    if seen.length() == 1 {
      @http.Response::new(
        302,
        headers=@http.Headers::of([
          ("Location", "https://elsewhere.invalid/model"),
        ]),
      )
    } else {
      response({ "name": "models/test" })
    }
  })
  let sdk = @gemini.Gemini::new(
    backend,
    @sim.FakeClock::new(),
    auth=ApiKey("offline-key"),
  )
  assert_true(
    @driver.run_sync(() => sdk.get_model(name="models/test")) is Ok(_),
  )
  assert_eq(seen, [Some("offline-key"), None])
}

///|
test "Gemini from_client marks the runtime-default key with anonymous SDK auth" {
  let origin = "https://gemini.example"
  let next = "https://other.example/probe"
  let seen = []
  let backend = @client.from_fn((request, _) => {
    seen.push(request)
    if request.url.has_prefix(origin) {
      @http.Response::new(307, headers=@http.Headers::of([("location", next)]))
    } else {
      @http.Response::new(200)
    }
  })
  let runtime = @client.Client::new(
    backend,
    @sim.FakeClock::new(),
    headers=@http.Headers::of([("x-goog-api-key", "fixture-key")]),
    redirect={ ..@client.RedirectConfig::default(), credential_headers: [], },
  )
  let sdk = @gemini.Gemini::from_client(runtime, base_url=origin)
  let raw = @http.Request::get("/probe").credential(
    "x-existing-key", "existing-key",
  )
  assert_true(@driver.run_sync(() => sdk.send(raw)) is Ok(_))
  assert_eq(seen.length(), 2)
  assert_eq(seen[0].headers.get("x-goog-api-key"), Some("fixture-key"))
  assert_eq(seen[1].url, next)
  assert_eq(seen[1].headers.get("x-goog-api-key"), None)
  assert_eq(seen[1].headers.get("x-existing-key"), None)
  let curl = @client.request(seen[0]).response(@client.as_bytes()).to_curl()
  assert_true(curl.contains("x-goog-api-key: <redacted>"))
  assert_false(curl.contains("fixture-key"))
}
