///|
/// Uploads buffered bytes in a resumable session (start, then upload/finalize).
/// The session must be on this client's origin. Interrupted transfers are not resumed.
/// Handwritten because Discovery describes media endpoints but cannot express the
/// session URL returned in a header or the upload/finalize command sequence.
pub async fn Gemini::upload_file(
  self : Gemini,
  bytes : Bytes,
  mime_type~ : String,
  display_name? : String,
) -> Result[@gen.CreateFileResponse, Failure] {
  let operation = "media_upload"
  let metadata = @gen.CreateFileRequest::new(
    file=@gen.File::new(mime_type~, display_name?),
  )
  let start = @http.Request::post("/upload/v1beta/files")
    .header("X-Goog-Upload-Protocol", "resumable")
    .header("X-Goog-Upload-Command", "start")
    .header("X-Goog-Upload-Header-Content-Length", bytes.length().to_string())
    .header("X-Goog-Upload-Header-Content-Type", mime_type)
    .body_json(Json(metadata))
  let reply = match self.send(start, operation~) {
    Ok(reply) => reply
    Err(error) => return Err(error)
  }
  let head : @http.ResponseHead = {
    status: reply.status,
    headers: reply.headers,
  }
  let session = match reply.headers.get("x-goog-upload-url") {
    Some(url) => url
    None =>
      return Err(
        Decode(
          @client.Deserialization(
            head,
            message="missing X-Goog-Upload-URL",
            body=b"",
          ),
        ),
      )
  }
  let trusted = try {
    let url = @http.Url::parse(session)
    url.is_absolute() &&
    url.userinfo is None &&
    url.fragment is None &&
    url.same_origin(@http.Url::parse(self.base_url))
  } catch {
    _ => false
  }
  if !trusted {
    return Err(
      Decode(
        @client.Deserialization(
          head,
          message="upload session must be an absolute URL on the configured origin",
          body=b"",
        ),
      ),
    )
  }
  let finalize = @http.Request::post(session)
    .header("X-Goog-Upload-Offset", "0")
    .header("X-Goog-Upload-Command", "upload, finalize")
    .body_bytes(bytes, content_type=mime_type)
  self.call(finalize, @gen.media_upload_decode, operation~)
}
