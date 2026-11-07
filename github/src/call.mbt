///|
/// Sends a generated request and decodes the successful response.
///
/// The two arguments are the matched halves of one generated operation, so a
/// call reads as a single line:
///
///     let repo = gh.call(
///       @gen.repos_get_request("gaato", "mbt-sdk"),
///       @gen.repos_get_decode,
///     )
///
/// Failures arrive as `Error`; `api_error` reads GitHub's error
/// body out of one.
pub async fn[T, E : Error] GitHub::call(
  self : GitHub,
  request : @model.Request,
  decode : (@model.ResponseHead, Bytes) -> T raise E,
) -> T raise Error {
  self.send_with(
    request,
    @client.as_bytes().map_with_head((bytes, head) => decode(head, bytes)),
  ).body
}

///|
/// Sends a generated request and returns the successful response undecoded.
///
/// This is for the operations whose body a decoder cannot describe: `204` and
/// `304` replies, and the representations requested through a non-JSON `accept`
/// such as `application/vnd.github.diff`.
pub async fn GitHub::send(
  self : GitHub,
  request : @model.Request,
) -> @client.Reply[Bytes] raise Error {
  self.send_with(request, @client.as_bytes())
}

///|
async fn[T] GitHub::send_with(
  self : GitHub,
  request : @model.Request,
  reader : @client.ResponseAs[T],
) -> @client.Reply[T] {
  self.client.send(
    @client.ClientRequest::new(request, reader).attribute(
      @client.rate_limit_bucket,
      rate_limit_bucket(request.meth.to_string(), request.url),
    ),
  )
}

///|
/// The rate limit bucket a request belongs to, by method and URL.
///
/// GitHub meters search separately from the rest of the REST API, and the two
/// windows are far apart (30 requests per minute against 5,000 per hour), so
/// they must not share a limiter bucket. GraphQL is a third window, budgeted in
/// points rather than requests: the vendored specification lists `core`,
/// `graphql`, `search` and the rest as separate resources of
/// `/rate_limit`, and a GraphQL response names its own with
/// `x-ratelimit-resource: graphql`.
///
/// Writes get buckets of their own so they can be paced (`github_pace`):
/// any method but `GET` and `HEAD` is `"core:write"`, or
/// `"core:notifications"` on a path that sends notifications
/// (`triggers_notification`). Their state is still the `core` window, because
/// the limiter follows `x-ratelimit-resource`. `GitHub::graphql` names its
/// own bucket (`"graphql"` or `"graphql:mutation"`); a request sent to the
/// endpoint through `send` is `"graphql"`.
///
/// The URL is either the relative path a generated operation produced or the
/// absolute `Link` target of a following page, so the scheme and authority are
/// stripped first, along with the `/api/v3` mount a GitHub Enterprise Server
/// deployment puts in front of every path. GraphQL is not under that mount —
/// Enterprise Server serves it from `/api/graphql` — so both spellings appear
/// here.
fn rate_limit_bucket(http_method : String, url : String) -> String {
  let path = request_path(url)
  let read = http_method.to_upper() is ("GET" | "HEAD")
  if path == "/graphql" || path == "/api/graphql" {
    graphql_bucket
  } else if read {
    if path.has_prefix("/search/") {
      "search"
    } else {
      "core"
    }
  } else if triggers_notification(path) {
    "core:notifications"
  } else {
    "core:write"
  }
}

///|
/// How far apart the requests of a bucket start, after octokit's
/// `plugin-throttling` and docs.github.com's "wait at least one second between
/// each request" for mutative requests: writes and every GraphQL request
/// (which may mutate) at least 1 s apart, writes that send notifications 3 s,
/// and searches 2 s. All writes and GraphQL share the `"write"` group, so a
/// notification-sending write also holds the next plain write for 3 s, where
/// octokit keeps a separate 3 s queue for them; the stricter spacing meets
/// both of its limits. Reads are not paced.
fn github_pace(bucket : String) -> @ratelimit.Pace {
  match bucket {
    "core:write" | "graphql" | "graphql:mutation" =>
      { group: "write", min_interval_ms: 1000, }
    "core:notifications" => { group: "write", min_interval_ms: 3000, }
    "search" => { group: "search", min_interval_ms: 2000, }
    _ => { group: bucket, min_interval_ms: 0, }
  }
}

///|
/// The REST paths whose writes send notifications, from octokit's
/// `plugin-throttling` (`src/generated/triggers-notification-paths.ts` at
/// eb4215edcd97f20ade800b18d964bf798e0d70b7), split into segments.
let notification_paths : Array[Array[String]] = [
  "/orgs/{org}/invitations", "/orgs/{org}/invitations/{invitation_id}", "/orgs/{org}/teams/{team_slug}/discussions",
  "/orgs/{org}/teams/{team_slug}/discussions/{discussion_number}/comments", "/repos/{owner}/{repo}/collaborators/{username}",
  "/repos/{owner}/{repo}/commits/{commit_sha}/comments", "/repos/{owner}/{repo}/issues",
  "/repos/{owner}/{repo}/issues/{issue_number}/comments", "/repos/{owner}/{repo}/issues/{issue_number}/sub_issue",
  "/repos/{owner}/{repo}/issues/{issue_number}/sub_issues/priority", "/repos/{owner}/{repo}/pulls",
  "/repos/{owner}/{repo}/pulls/{pull_number}/comments", "/repos/{owner}/{repo}/pulls/{pull_number}/comments/{comment_id}/replies",
  "/repos/{owner}/{repo}/pulls/{pull_number}/merge", "/repos/{owner}/{repo}/pulls/{pull_number}/requested_reviewers",
  "/repos/{owner}/{repo}/pulls/{pull_number}/reviews", "/repos/{owner}/{repo}/releases",
  "/teams/{team_id}/discussions", "/teams/{team_id}/discussions/{discussion_number}/comments",
].map(path_segments)

///|
/// Whether a write to `path` sends notifications. A `{parameter}` matches one
/// non-empty segment and a literal segment matches regardless of case.
/// Octokit's own matcher is a looser regular expression (a parameter may span
/// slashes, and anything without a slash may follow the last segment); since
/// no owner, repository or number contains a slash, matching whole segments
/// gives the same answer for every real path without its accidental matches.
fn triggers_notification(path : String) -> Bool {
  let segments = path_segments(path)
  notification_paths
  .iter()
  .any(pattern => {
    pattern.length() == segments.length() &&
    pattern
    .iter()
    .zip(segments.iter())
    .all(pair => {
      let (expected, actual) = pair
      if expected.has_prefix("{") {
        !actual.is_empty()
      } else {
        expected.to_lower() == actual.to_lower()
      }
    })
  })
}

///|
/// The segments of a path, without the empty one before its leading slash.
fn path_segments(path : String) -> Array[String] {
  let segments = path.split("/").map(segment => segment.to_owned()).collect()
  if segments.length() > 0 && segments[0].is_empty() {
    segments.remove(0) |> ignore
  }
  segments
}

///|
/// Extracts the path of an absolute or relative request URL.
fn request_path(url : String) -> String {
  let mut rest = url
  let mut absolute = true
  if url.has_prefix("https://") {
    rest = url[8:].to_owned()
  } else if url.has_prefix("http://") {
    rest = url[7:].to_owned()
  } else if url.has_prefix("//") {
    rest = url[2:].to_owned()
  } else {
    absolute = false
  }
  if absolute {
    rest = match rest.find("/") {
      Some(index) => rest[index:].to_owned()
      None => "/"
    }
  }
  if rest.find("#") is Some(index) {
    rest = rest[:index].to_owned()
  }
  if rest.find("?") is Some(index) {
    rest = rest[:index].to_owned()
  }
  if !rest.has_prefix("/") {
    rest = "/" + rest
  }
  if rest.has_prefix("/api/v3/") {
    rest = rest[7:].to_owned()
  }
  rest
}
