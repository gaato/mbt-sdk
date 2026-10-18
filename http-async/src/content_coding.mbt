///|
/// A content coding (RFC 9110 section 8.4.1) the transport can undo.
priv enum Coding {
  Gzip
  Deflate
}

///|
/// Every coding the transport undoes, in the order `Accept-Encoding` lists them.
let decodable_codings : Array[Coding] = [Gzip, Deflate]

///|
/// The most codings one `Content-Encoding` may list, as urllib3 and httpx2
/// allow. Each coding the transport undoes holds its own window and buffers.
let max_content_codings : Int32 = 5

///|
fn Coding::name(self : Coding) -> String {
  match self {
    Gzip => "gzip"
    Deflate => "deflate"
  }
}

///|
/// The `Accept-Encoding` the transport sends when the request has none: every
/// coding it undoes and nothing else, so a server never picks one it cannot.
fn accept_encoding() -> String {
  decodable_codings.map(Coding::name).join(", ")
}

///|
/// The coding a `Content-Encoding` token names, if the transport undoes it.
/// RFC 9110 section 8.4.1.3 asks a recipient to take `x-gzip` as `gzip`.
fn coding_of(token : String) -> Coding? {
  match token {
    "gzip" | "x-gzip" => Some(Gzip)
    "deflate" => Some(Deflate)
    _ => None
  }
}

///|
/// What to do with a response's `Content-Encoding`.
priv struct CodingPlan {
  /// The codings to undo, last applied first.
  undo : Array[Coding]
  /// The codings left on the body once those are undone, as the header should
  /// then read; `None` when none are left.
  remaining : String?
}

///|
/// Plans the decoding of a body whose `Content-Encoding` field lines are
/// `values`. Codings are undone from the last applied while the transport
/// knows them; an unknown one, and every coding applied before it, stays on
/// the body and in the header, as httpx and Go's transport leave it. `identity`
/// and empty list elements are ignored. More than `max_content_codings`
/// codings raise `Protocol`.
fn coding_plan(values : Array[String]) -> CodingPlan raise @http.HttpError {
  let tokens = []
  for value in values {
    for element in value.split(",") {
      let token = element.trim(chars=" \t").to_owned()
      let lowered = token.to_lower()
      if lowered != "" && lowered != "identity" {
        tokens.push((token, lowered))
      }
    }
  }
  if tokens.length() > max_content_codings {
    raise @http.HttpError::Protocol(
      "response has \{tokens.length()} content codings, more than \{max_content_codings}",
    )
  }
  let undo = []
  let mut kept = tokens.length()
  while kept > 0 && coding_of(tokens[kept - 1].1) is Some(coding) {
    undo.push(coding)
    kept -= 1
  }
  let remaining = if kept == 0 {
    None
  } else {
    Some(tokens[:kept].iter().map(token => token.0).join(", "))
  }
  { undo, remaining, }
}

///|
/// The decoder for a body whose head is `head`, or `None` when there is
/// nothing to undo. With a decoder, `head` is edited in place to describe the
/// decoded body: `Content-Length`, which counted the coded bytes, is dropped,
/// and `Content-Encoding` names only the codings left, if any.
fn decode_head(
  head : @http.ResponseHead,
) -> ContentDecoder? raise @http.HttpError {
  let plan = coding_plan(head.headers.get_all("content-encoding"))
  if plan.undo.is_empty() {
    return None
  }
  head.headers.remove("content-length")
  match plan.remaining {
    Some(remaining) => head.headers.set("content-encoding", remaining)
    None => head.headers.remove("content-encoding")
  }
  Some(ContentDecoder::new(plan.undo))
}
