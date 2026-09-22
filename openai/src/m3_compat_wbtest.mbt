///|
fn decode_model(value : Json) -> Model raise @json.JsonDecodeError {
  let decoded : @gen.Model = @json.from_json(value)
  {
    id: decoded.id,
    created: Some(decoded.created),
    owned_by: decoded.owned_by,
  }
}

///|
fn decode_embedding_response(
  value : Json,
) -> EmbeddingResponse raise @json.JsonDecodeError {
  let decoded : @gen.CreateEmbeddingResponse = @json.from_json(value)
  {
    data: decoded.data.map(item => {
      index: item.index,
      embedding: item.embedding,
    }),
    model: decoded.model,
    prompt_tokens: decoded.usage.prompt_tokens,
    total_tokens: decoded.usage.total_tokens,
  }
}
