///|
/// Follows Link next URLs, advancing only after a successful decoded page.
pub fn[T] GitHub::paginator(
  self : GitHub,
  first : @http.Request,
  decode : (@http.ResponseHead, Bytes) -> Result[
    Array[T],
    @client.ResponseFailure,
  ] raise?,
) -> @client.Paginator[T, GitHubFailure] {
  @client.Paginator::with_cursor(cursor => {
    let request = match cursor {
      Some(url) => { ..first, url, }
      None => first
    }
    let reply = self.send_with(
      request,
      @client.as_bytes().map_with_head((result, head) => {
        match result {
          Err(error) => Err(Http(error))
          Ok(bytes) =>
            match decode(head, bytes) {
              Ok(items) => Ok(items)
              Err(error) => Err(Http(error))
            }
        }
      }),
    )
    match reply.body {
      Err(error) => Err(error)
      Ok(items) =>
        Ok(@client.Page::{
          items,
          next: @client.parse_link_next(reply.headers),
        })
    }
  })
}
