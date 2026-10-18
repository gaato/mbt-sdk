///|
/// Reports whether the method is idempotent or an idempotency key is present.
pub fn is_idempotent(request : Request) -> Bool {
  if request.headers.contains("idempotency-key") {
    return true
  }
  match request.http_method.to_lower() {
    "get" | "head" | "put" | "delete" | "options" | "trace" => true
    _ => false
  }
}
