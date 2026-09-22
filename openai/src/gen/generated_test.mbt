///|
fn response(body : String) -> @http.Response {
  { status: 200, headers: @http.Headers::new(), body: @utf8.encode(body), }
}

///|
test "generated model decoders accept spec fixtures and Int64 above Int32" {
  let listed = @gen.list_models_decode(
    response(
      "{\"object\":\"list\",\"data\":[{\"id\":\"model-id-0\",\"object\":\"model\",\"created\":2147483648,\"owned_by\":\"organization-owner\"}]}",
    ),
  )
  assert_eq(listed.data.length(), 1)
  assert_eq(listed.data[0].id, "model-id-0")
  assert_eq(listed.data[0].created, 2147483648L)
  assert_eq(listed.data[0].owned_by, Some("organization-owner"))

  let model = @gen.retrieve_model_decode(
    response(
      "{\"id\":\"gpt-4o-mini\",\"object\":\"model\",\"created\":1686935002,\"owned_by\":\"openai\"}",
    ),
  )
  assert_eq(model.id, "gpt-4o-mini")
}

///|
test "generated embedding response decoder accepts the M3 fixture" {
  let decoded = @gen.create_embedding_decode(
    response(
      "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"embedding\":[0.0023064255,-0.009327292],\"index\":0}],\"model\":\"text-embedding-ada-002\",\"usage\":{\"prompt_tokens\":8,\"total_tokens\":8}}",
    ),
  )
  assert_eq(decoded.model, "text-embedding-ada-002")
  assert_eq(decoded.data.length(), 1)
  assert_eq(decoded.data[0].index, 0)
  assert_eq(decoded.data[0].embedding, [0.0023064255, -0.009327292])
  assert_eq(decoded.usage.prompt_tokens, 8)
  assert_eq(decoded.usage.total_tokens, 8)
}

///|
test "embedding request input variants round-trip and unknown request enums survive" {
  let inputs : Array[@gen.CreateEmbeddingRequestInput] = [
    @gen.Text("hello"),
    @gen.TextArray(["one", "two"]),
    @gen.IntArray([1212, 318]),
    @gen.IntArrayArray([[1212], [318, 257]]),
  ]
  for input in inputs {
    let original : @gen.CreateEmbeddingRequest = {
      input,
      model: "text-embedding-3-small",
      encoding_format: Some(@gen.Custom("future-format")),
      dimensions: Some(2),
      user: None,
    }
    let request = @gen.create_embedding_request(original)
    let decoded : @gen.CreateEmbeddingRequest = @json.from_json(
      @json.parse(@utf8.decode(request.body)),
    )
    match (input, decoded.input) {
      (@gen.Text(expected), @gen.Text(actual)) => assert_eq(actual, expected)
      (@gen.TextArray(expected), @gen.TextArray(actual)) =>
        assert_eq(actual, expected)
      (@gen.IntArray(expected), @gen.IntArray(actual)) =>
        assert_eq(actual, expected)
      (@gen.IntArrayArray(expected), @gen.IntArrayArray(actual)) =>
        assert_eq(actual, expected)
      _ => fail("embedding input variant changed during round-trip")
    }
    match decoded.encoding_format {
      Some(@gen.Custom(value)) => assert_eq(value, "future-format")
      _ => fail("unknown enum value was not retained as Custom")
    }
  }
}

///|
test "missing required generated response field becomes SdkError Decode" {
  try
    @gen.retrieve_model_decode(
      response("{\"created\":1,\"owned_by\":\"openai\"}"),
    )
  catch {
    @runtime.Decode(body~, ..) =>
      assert_eq(body, b"{\"created\":1,\"owned_by\":\"openai\"}")
    _ => fail("expected SdkError::Decode")
  } noraise {
    _ => fail("missing id must fail")
  }
}

///|
test "retrieve model request percent-encodes every non-unreserved path byte" {
  let request = @gen.retrieve_model_request("model/id with space")
  assert_eq(request.http_method, "GET")
  assert_eq(request.url, "/models/model%2Fid%20with%20space")
}
