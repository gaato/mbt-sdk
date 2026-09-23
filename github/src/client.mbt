///|
/// A GitHub API client backed by the transport-independent SDK runtime.
///
/// REST request and response shapes come from the generated `gen` package,
/// which is produced from the vendored first-party OpenAPI document. This facade
/// does not restate them: it only sends a generated request, follows `Link`
/// pages, and reads GitHub's error bodies.
///
/// GraphQL has no such generated vocabulary — a reply's shape belongs to the
/// caller's query rather than to the schema — so it is served by the `graphql`
/// passthrough over `Json`.
pub struct GitHub {
  priv client : @runtime.Client
  priv graphql_url : String
}

///|
/// Redacted debug representation of a GitHub client.
pub extend GitHub with @debug.Debug::{to_repr}

///|
/// Formats a client without exposing authentication or other runtime internals.
pub impl @debug.Debug for GitHub with fn to_repr(_self) {
  @debug.Repr::ctor("GitHub", [
    (None, @debug.Repr::literal("<credentials redacted>")),
  ])
}

///|
/// Creates a GitHub client.
///
/// `token` is optional: GitHub serves public resources unauthenticated, so an
/// absent token means `NoAuth` rather than a configuration error. A present
/// token is sent as `Authorization: Bearer`, which covers personal access
/// tokens, installation tokens, and `GITHUB_TOKEN`.
///
/// `base_url` is the API root. GitHub Enterprise Server mounts the REST API
/// under `/api/v3`, so pass `https://ghe.example.com/api/v3` there.
///
/// The default headers are `accept: application/vnd.github+json`,
/// `x-github-api-version`, and `user-agent`, which GitHub requires. A generated
/// operation that needs a different representation — `application/vnd.github.diff`,
/// `.patch`, `.sarif` — sets `accept` on its own request, and the runtime keeps
/// request headers ahead of client defaults.
///
/// Unless `limiter` says otherwise, responses feed a `WindowLimiter` reading
/// `x-ratelimit-remaining` and `x-ratelimit-reset`. Pass
/// `limiter=@runtime.NoLimiter::new()` to opt out.
///
/// `graphql_url` is the GraphQL endpoint, which is not under the REST root:
/// GitHub Enterprise Server serves REST from `/api/v3` and GraphQL from
/// `/api/graphql`. It is derived from `base_url` and only needs passing for a
/// deployment that puts the two somewhere else.
pub fn GitHub::new(
  transport : &@http.Transport,
  clock : &@clock.Clock,
  token? : String,
  base_url? : String = "https://api.github.com",
  api_version? : String = "2022-11-28",
  user_agent? : String = "gaato-mbt-sdk/0.1.0",
  retry? : @runtime.RetryPolicy,
  limiter? : &@runtime.RateLimiter,
  graphql_url? : String,
) -> GitHub {
  let auth = match token {
    Some(token) => @runtime.Bearer(token)
    None => @runtime.NoAuth
  }
  let limiter : &@runtime.RateLimiter = match limiter {
    Some(limiter) => limiter
    None => default_limiter(clock)
  }
  let graphql_url = match graphql_url {
    Some(url) => url
    None => default_graphql_url(base_url)
  }
  {
    client: @runtime.Client::new(
      transport,
      clock,
      base_url~,
      default_headers=default_headers(api_version~, user_agent~),
      auth~,
      retry?,
      limiter~,
    ),
    graphql_url,
  }
}

///|
/// Wraps a preconfigured runtime client.
///
/// This is the escape hatch for deployments this facade does not model — a
/// proxy that authenticates differently, a GitHub Enterprise Server instance
/// with extra headers — and for tests that build the client themselves.
///
/// A runtime client keeps its `base_url` to itself, so the GraphQL endpoint
/// cannot be derived from it here and defaults to GitHub's own. Pass
/// `graphql_url` for anything else.
pub fn GitHub::from_client(
  client : @runtime.Client,
  graphql_url? : String = "https://api.github.com/graphql",
) -> GitHub {
  { client, graphql_url, }
}

///|
/// The headers every request carries unless the request sets them itself.
fn default_headers(
  api_version~ : String,
  user_agent~ : String,
) -> @http.Headers {
  @http.Headers::from_array([
    ("accept", "application/vnd.github+json"),
    ("x-github-api-version", api_version),
    ("user-agent", user_agent),
  ])
}

///|
/// The GraphQL endpoint that goes with a REST root.
///
/// GraphQL is not mounted under the REST root. GitHub Enterprise Server serves
/// REST from `http(s)://HOSTNAME/api/v3` and GraphQL from
/// `http(s)://HOSTNAME/api/graphql`, so appending `/graphql` to a `/api/v3`
/// root would address an endpoint that does not exist. On GitHub.com the two
/// share a host and appending is right.
fn default_graphql_url(base_url : String) -> String {
  let root = if base_url.has_suffix("/") {
    base_url[:base_url.length() - 1].to_owned()
  } else {
    base_url
  }
  if root.has_suffix("/api/v3") {
    // Keep everything up to and including "/api/", then name the other API.
    root[:root.length() - 2].to_owned() + "graphql"
  } else {
    root + "/graphql"
  }
}

///|
/// The rate limit window GitHub advertises on every response.
fn default_limiter(clock : &@clock.Clock) -> @runtime.WindowLimiter {
  @runtime.WindowLimiter::new(
    clock,
    @runtime.rate_limit_headers(
      remaining="x-ratelimit-remaining",
      reset_unix_seconds="x-ratelimit-reset",
    ),
  )
}
