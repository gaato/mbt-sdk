///|
/// A GitHub REST API client backed by the transport-independent SDK runtime.
///
/// Request and response shapes come from the generated `gen` package, which is
/// produced from the vendored first-party OpenAPI document. This facade does
/// not restate them: it only sends a generated request, follows `Link` pages,
/// and reads GitHub's error bodies.
pub struct GitHub {
  priv client : @runtime.Client
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
pub fn GitHub::new(
  transport : &@http.Transport,
  clock : &@clock.Clock,
  token? : String,
  base_url? : String = "https://api.github.com",
  api_version? : String = "2022-11-28",
  user_agent? : String = "gaato-mbt-sdk/0.1.0",
  retry? : @runtime.RetryPolicy,
  limiter? : &@runtime.RateLimiter,
) -> GitHub {
  let auth = match token {
    Some(token) => @runtime.Bearer(token)
    None => @runtime.NoAuth
  }
  let limiter : &@runtime.RateLimiter = match limiter {
    Some(limiter) => limiter
    None => default_limiter(clock)
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
  }
}

///|
/// Wraps a preconfigured runtime client.
///
/// This is the escape hatch for deployments this facade does not model — a
/// proxy that authenticates differently, a GitHub Enterprise Server instance
/// with extra headers — and for tests that build the client themselves.
pub fn GitHub::from_client(client : @runtime.Client) -> GitHub {
  { client, }
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
