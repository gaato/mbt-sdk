///|
/// A cookie's `SameSite` attribute (RFC 6265bis-22). `NoRestriction` is
/// `SameSite=None`.
pub(all) enum SameSite {
  Strict
  Lax
  NoRestriction
} derive(Eq, Debug)

///|
/// Compares attribute values.
pub extend SameSite with Eq::{equal, not_equal}

///|
/// Debug representation of the attribute value.
pub extend SameSite with @debug.Debug::{to_repr}

///|
/// A stored cookie, with the fields of the RFC 6265 §5.3 storage model.
///
/// `domain` is the request host for a host-only cookie and the `Domain`
/// attribute otherwise. `expires_ms` is `None` for a session cookie. Times are
/// Unix milliseconds from the jar's clock; `last_access_ms` is when the cookie
/// was last stored or sent.
pub struct Cookie {
  name : String
  value : String
  domain : String
  host_only : Bool
  path : String
  expires_ms : Int64?
  secure : Bool
  http_only : Bool
  same_site : SameSite?
  creation_ms : Int64
  last_access_ms : Int64
} derive(Eq, Debug)

///|
/// Compares every field.
pub extend Cookie with Eq::{equal, not_equal}

///|
/// Debug representation of every field.
pub extend Cookie with @debug.Debug::{to_repr}

///|
/// Whether the cookie has expired at `now_ms`.
pub fn Cookie::is_expired(self : Cookie, now_ms : Int64) -> Bool {
  self.expires_ms is Some(expires) && expires <= now_ms
}
