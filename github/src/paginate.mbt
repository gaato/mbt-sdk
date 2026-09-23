///|
/// Walks a `Link`-paginated collection starting from a generated request.
///
/// GitHub paginates with RFC 8288 `Link` headers rather than a cursor in the
/// body, so the paginator's cursor is the `rel="next"` URL exactly as the
/// server wrote it: absolute, and already carrying the page size and every
/// filter of the first request. `@runtime.Client` resolves an absolute request
/// URL by passing it through, so the following pages need no rebuilding here.
///
/// The decoder is the generated `<operation>_decode` of an operation whose
/// success type is an array:
///
///     let repos = gh
///       .paginator(
///         @gen.repos_list_for_user_request("gaato", per_page=100),
///         @gen.repos_list_for_user_decode,
///       )
///       .collect(max=250)
///
/// A search operation does not answer this shape: its payload is an envelope
/// with `items` and `total_count`, so wrap `search_*_decode` in a decoder that
/// returns the `items` field.
pub fn[T] GitHub::paginator(
  self : GitHub,
  first : @http.Request,
  decode : (@http.Response) -> Array[T] raise @runtime.SdkError,
) -> @runtime.Paginator[T] {
  @runtime.Paginator::new(cursor => {
    let request = match cursor {
      Some(url) => { ..first, url, }
      None => first
    }
    let response = self.send(request)
    @runtime.Page::{
      items: decode(response),
      next: @runtime.parse_link_next(response.headers),
    }
  })
}
