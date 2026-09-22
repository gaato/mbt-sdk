///|
test "form explode repeats array query names" {
  let request = find_pets_by_tags_request(["a b", "日本語&="])
  assert_eq(
    request.url,
    "/pet/findByTags?tags=a%20b&tags=%E6%97%A5%E6%9C%AC%E8%AA%9E%26%3D",
  )
}

///|
test "header values are stringified without query escaping" {
  let request = delete_pet_request(1L, api_key="MiXeD & value")
  assert_eq(request.headers.get("api_key"), Some("MiXeD & value"))
}

///|
test "typed map response decodes and encodes as a JSON object" {
  let response : @http.Response = {
    status: 200,
    headers: @http.Headers::new(),
    body: @utf8.encode("{\"available\":2,\"pending\":1}"),
  }
  let inventory = get_inventory_decode(response)
  assert_eq(inventory.get("available"), Some(2))
  assert_eq(inventory.to_json(), @json.parse("{\"available\":2,\"pending\":1}"))
}
