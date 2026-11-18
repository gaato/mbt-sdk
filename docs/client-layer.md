# Generated clients

`client_layer = true` opts an unpublished SDK into facade generation. Published
facades keep their existing API. The type is the SDK name in PascalCase
(`Jina`, `Replicate`); it lives in the root package, so handwritten methods
can be added there. Generated root sources carry the generator header and
end in `_gen.mbt`. `moon.pkg` is generated too; additional handwritten imports
are ledger `extra_imports` module paths. This is the package-file exception to
the root source naming rule. The older fixtures keep their vocabulary in the
root package; their builders and types stay unchanged, while package imports
and the root interface necessarily include the new facade.
The ledger's registered flat vocabulary outputs (`types.mbt`, `operations.mbt`)
remain generator-owned when they carry the header, so future specification
changes can regenerate them. This exception grants no ownership to other root
filenames.

## Construction and calls

`Sdk::new(backend, clock, auth=Bearer(token))` leaves backend selection to the
application and depends only on mttp_core. `Sdk::from_client(client, auth=...)`
wraps a caller-owned runtime client without changing its policies. Both accept
`base_url` and `server_urls`, the latter mapping original spec server URLs to
replacements. Relative server overrides resolve against the main base URL.
Defaults come from pinned ledger values. The SDK does not close a shared
runtime Client; its owner controls its lifetime and retry budget.

`Auth` provides `Anonymous`, bearer/basic credentials and named header/query
API-key alternatives declared in the pin. An OAuth2 security scheme accepts
an already obtained bearer token; it performs no OAuth flow. Security arrays
are OR alternatives; AND requirements are rejected. With no security declaration
the pinned constructor auth applies. An empty requirement object (`{}`) or an
operation-level empty array (`security: []`) is the `Anonymous` alternative and
prevents credentials from being attached. Auth header
parameters disappear from facade signatures. Legacy fixture builders retain
their existing parameters, allowing vocabulary output to stay stable.

`call(request, decode)` pairs a generated request with its decoder. `send`
returns `Reply[Bytes]` after consuming the body, retaining status and headers.
Generic calls infer operations from relative paths or from absolute URLs within
the configured operation base, including server replacements; public operations
therefore keep their no-auth rule on both paths.

New modules may opt into `x-moonbit-nonraising-decoders: true` in their overlay.
Their generic `call` accepts a decoder returning `Result` without raising. This
avoids a link-core assertion in the pinned compiler when a typed async wrapper
instantiates a `raise?` callback. Gemini uses this mode; existing module callback
contracts and output remain unchanged. Streaming callback errors still propagate.

For a wire oneof selected by the presence of a field, an overlay can use `oneOf`
plus `x-moonbit-discriminator-fields`, with one field name per payload schema.
Each payload must require that field and exclude every other variant field.
This generates a union with flat JSON and rejects missing or ambiguous data.
Gemini's Part payloads retain their common metadata fields alongside the chosen
data field, so thought signatures and video metadata survive a round trip.

Google Discovery top-level parameters are system-wide controls, so they are
intentionally absent from every generated operation signature. API keys and
OAuth access tokens use the generated `Auth` alternatives. For another optional
system parameter such as `fields`, `quotaUser`, `prettyPrint`, `alt`, or
`$.xgafv`, build the ordinary request with
`@gen.<operation>_request(...)`, add it with
`.query("fields", value)` (or the corresponding parameter name), and pass the
result to `call(request, @gen.<operation>_decode)`. Use `send(request)` instead
when consuming the raw buffered response or applying a custom decoder. A
method-level parameter with the same name is still emitted on that method and
does not require this generic path. A required non-auth top-level parameter is
rejected during generation because silently omitting it would make every
affected request invalid.
Discovery operations use their canonical `path`, not `flatPath`, so returned
resource names can be passed back with the original `name` or `model` label.
An exact `^collection/[^/]+$` pattern additionally accepts a bare ID by prepending
the collection. Other patterns require a full name. Every name is checked against
the whole pattern, with URL delimiters, percent escapes, whitespace, backslashes,
empty segments and dot segments rejected before request construction. Low-level
builders raise `ValidationError`; facade methods return `Failure::Validation`.
When distinct Google methods reuse a path template with different collection
patterns, the converter gives their internal OpenAPI dictionary entries unique
keys and records `x-moonbit-request-path`. IR and emitted requests retain the
original wire template. Generic call inference uses the collection patterns too.
Discovery security scheme names become the auth variant names (`ApiKey`,
`ApiKeyInQuery`, `OAuthToken`); OpenAPI SDKs retain their existing naming rule.
References to fieldless protobuf messages yield Unit responses; empty OpenAPI
object schemas retain their ordinary arbitrary-object semantics.
Operation methods default on; `operation_wrappers = false` leaves the generic
surface for large specs. Required path/query parameters use labels derived from
spec names in snake case, with keyword escaping; request bodies stay positional.
Only client method names drop an exact FastAPI `_<sanitized-path>_<method>`
suffix from the operation ID. The sanitization replaces each non-word character
with an underscore, preserving doubled underscores around path parameters.
Colliding shortened names fall back to full IDs. `x-moonbit-name` overrides
the name (normalized to snake case); unresolved/explicit collisions fail
generation. The `src/gen` names and files retain their existing form.

JSON operations have typed results. Raw request bodies take positional `Bytes`
and `content_type`. Binary results are buffered raw replies, `text/*` results
are strict UTF-8 strings (`Failure::Decode` on invalid input), and operations
with no declared content return `Unit`; all consume or close the body.
An SSE-only operation accepts `receive` and optional `stop`; mixed JSON/SSE
operations have an additional `_stream` method. The generic `stream` uses
`as_sse`, closing the body at EOF, stop, failure or callback exit.

## Safety and defaults

Generated constructor references carry their owning type, including in matches
and shared helpers: `TheEnum::None`, `TheEnum::Json(value)`, `Option::Some`,
`Result::Ok`, and `@json.Json::Json(value)`. Legal wire constructors retain
their existing names and public API. Qualification avoids ambiguity when two
enums export `Json`, or when a variant shares a prelude name.

Identifier normalization retains the existing snake/Pascal case and sign rules.
Empty or punctuation-only field/parameter names (including `~`) become `value`;
leading digits receive `value_` (`Value` for types/variants). MoonBit keywords
and compiler-reserved lowercase words receive a trailing underscore; the
boolean literals `true` and `false`, and `noraise`, are included. Builtin
constructor names are not a rename table. Existing normalization collision
checks still apply; field normalization collisions retain their existing
numbered-name note. JSON names and discriminator values remain unchanged.

Types that the pinned compiler rejects with error 4003 receive `Value`:
`Option`, `String`, `Unit`, `Bool`, `Bytes`, `FixedArray`, `Int`, `Int32`,
`Int64`, `UInt`, `UInt32`, `UInt64`, `Double`, `Float`, `Byte`, `Char`,
`StringView`, `BytesView`, `ReadOnlyArray`, and `Error`. This is a type-only
table: legal types and constructors such as `Json`, `Result`, `None`, `Some`,
`Ok` and `Err` retain their names. Helpers also qualify builtin types when a
legal schema name would shadow one. Normalized type collisions retain the
existing declaration diagnostic.

Generated request locals/formals `url`, `request`, `parts`, `body`, and
`boundary` acquire trailing underscores only when they collide with API
parameters or multipart formals. The allocator checks each candidate again,
so the choice is deterministic. It moves generated names aside without
changing an API parameter's label.

From mttp_core 0.3.0, the SDK marks its declared credential header names on
each request. With `from_client`, this covers matching Client defaults even
when SDK auth is anonymous. The constructor also includes its header
API keys in the runtime redirect credential list. Marked headers are removed
when a redirect changes host, port or scheme, except for a same-host HTTP
port 80 to HTTPS port 443 upgrade. HTTPS to HTTP is refused by default.
`to_curl` redacts marked values. Supply credentials through `Auth`, keeping
default runtime headers credential-free so public operations can disable authentication.
Query credentials appear in redirect history and observer URLs. Absolute
pagination URLs outside the operation's origin receive no construction-time
credentials. Debug representations redact credentials.

Every request gets a provider-prefixed rate-limit bucket and operation ID.
`default_retry()` is conservative without a ledger retry table. No shared vendor
preset is introduced. Ledger `timeout_ms` sets the `new` constructor's default
per-attempt timeout; `total_timeout_ms` can likewise supply a total default.
Absent fields leave those timeouts unset. Constructor arguments override them.
Backend SendOptions enforce attempt deadlines; a supplied timer also bounds
runtime waits, and total deadlines require a timer. Connect/phase limits remain
backend configuration because mttp_core's Client has no connect-timeout option.
`from_client` uses its supplied policies. Buffered bodies keep
mttp_core's 64 MiB default and HTTP diagnostic bodies its bounded excerpt.
`Failure` separates HTTP operation/status/head/body (with `ErrorBody` when decodable),
transport kind/phase and successful-response decoding errors. Matches need a
default arm. `ErrorBody` has one variant per distinct error schema, named after
that schema, rather than per operation/status. Identical inline schemas share
one lowered type; the operation ID and actual status live in `HttpFailure`.
Declared 4xx and 5xx schemas and their status ranges are decoded, with an exact
status preferred over a range, then default. Pagination and text decoding keep
only `@client.max_error_body` diagnostic bytes on failure.
Cancellation and unknown user callback errors propagate. A Refused
failure means the request was **not processed**, rather than implying no bytes
were sent.

Explicit SDK request header values retain their bytes. Invalid values, including
those with surrounding whitespace, return `Failure::Validation` before I/O.
The supplied Client validates its defaults. Its header errors return
`Failure::Transport` with kind `Invalid` and phase `Pool`, like other
runtime transport failures carried in the result. User callback errors
propagate unchanged. Header parameters declared as API keys carry the
credential mark even on raw builders.
Statuses 600–999 are HTTP failures like 5xx. Provider defaults retry them
only through an explicit override such as `x-should-retry: true`.

Ledger `idempotency_headers` (or overlay `x-moonbit-idempotency-headers`) mark
requests replay-safe only when a nonempty header is supplied. They never invent
keys. Stream uploads cannot be replayed after consumption.

## Ledger policy and overlay pagination

`auth` kinds are `none`, `bearer`, `basic`, `header` or `query` (the latter two
need `name`); `alternatives` has a `schemes` array of those tables. Pins must
match spec security schemes. Missing definitions can be supplied by an overlay's
`x-moonbit-auth` security-scheme map with an explicitly reviewed missing-spec
baseline (`auth_reason` and `auth_spec`). `server_urls` pins all path/operation
server URLs, so upstream host changes fail synchronization for review.

The optional `[sdk.retry]` table accepts `retries`, `methods` and `sent_failures`
(`idempotent`, `any`, `never`, or a method-name array), `statuses` (codes or
inclusive two-code arrays), `unprocessed_failures`, `override_header`,
`retry_after` (`ignore`, `header`, `ms_then_header`), `retry_after_cap_ms`
(integer or `"none"`), `retry_after_cap` (`stop` or `backoff`),
`zero_means_backoff`, `backoff_base_ms`, `backoff_max_ms`, and `jitter`
(`none`, `full`, or two per-mille bounds). Omitted fields use the conservative
values. `status_overrides = [{methods = ["POST"], statuses = [429]}]` adds
those methods for those statuses. The emitter unions method sets by status,
then emits disjoint rules, because mttp selects the first status match.
Provider rules require a behavior survey before publication.

Jina uses conservative retry and a 60-second attempt timeout: no B source
justifies retrying all compute methods. Reader body-level retryAfter values
are not read. Replicate uses five retries, safe methods on the selected transient
statuses and POST on 429 only, with no transport retries. Header Retry-After
above 60 seconds falls back to backoff. Its 500 ms to 60 s exponential backoff
uses continuous proportional jitter 0.9–1.1 to express ±10% with mttp's model;
its attempt timeout is 70 seconds for Prefer: wait. See the dated provider
notes for the survey evidence and differences between official SDKs.

An operation overlay can declare:

```yaml
x-moonbit-paginate: {kind: cursor, param: page_token, items: results, next: next_page_token}
# Or:
x-moonbit-paginate: {kind: url, items: results, next: next}
```

`items` and `next` allow dotted JSON field paths. An operation's `_pages` method
takes the same arguments as the operation and builds the first request itself.
It yields `Paginator[Item, Failure]`, with Item taken from the response field's
array schema. An unrepresentable item type falls back to Json with a census
note. Item decoding must succeed before the cursor advances.
The generic `paginate[T](first, kind=NextUrl, items=..., next=...)` remains for
custom calls: `PageKind` is an enum (`NextUrl` or `Cursor(parameter_name)`), so
an invalid kind string cannot silently select a different protocol. Dotted
field names remain strings because they address JSON documents.
Empty intermediate pages are skipped when a next
cursor exists; null/absent/empty next stops. Failed decoding or transport does
not advance. Cursor replacement preserves other query parameters. Offset/limit
pagination is deferred until a concrete SDK needs it.
An omitted items field is an empty page, as protobuf JSON may omit empty
repeated fields. A present non-array field or a non-object path traversal is a
decode failure; an empty page with a next cursor still advances.
Next-URL references resolve against the effective URL of the successful page
(after redirects). Query-relative, path-relative and root-relative references
therefore retain the correct endpoint without duplicating a base path. Each
resolved URL still passes the operation-origin credential check.

Each enabled SDK gets generated offline backend tests for credentials, redirects,
servers, errors, retry policy, pagination and SSE stop/closure. The behavior-note
gate requires a dated, completed survey for published or enabled SDKs. An
unpublished entry may use `behavior_note = "pending: <reason>"` while a separate
research task owns the survey; publication cannot use that deferral.

## Options for enveloped OpenAPI resources

An overlay may name a security variant with `x-moonbit-auth-variant`.
`type: x-moonbit-header-bundle` defines one credential with a `headers` map
from constructor field names to wire header names. Its ledger alternative
uses `kind = "header_bundle"`, the same headers, and an optional `variant`.
Each header is validated, marked and redacted. A facade with
`x-moonbit-require-auth: true` requires an explicit credential.

`x-moonbit-operation-naming: fern` uses Fern's method and dotted group to
name facade methods. Nested groups drop trailing scope names `zone` and
`account`. Create and singleton CRUD methods use a singular resource name.
A `scan-<verb>` becomes `<verb>_<resource>_scan`. An operation's explicit
`x-moonbit-name` takes precedence.

`x-moonbit-envelope` maps the schema's result, success, errors and messages
keys to their on-wire names. The facade reports a false success flag as an
HTTP failure with its response head, bounded bytes and structured messages.
Typed success decoders return the configured result. Use the generic
`send` when you need the full successful envelope.

Typed operations and paginators reuse the parse that checks the success flag.
A declared JSON envelope without a result validates its required metadata
before returning Unit. An omitted result decodes to None when the result is
both nullable and optional. `x-moonbit-nullable-fields` can mark fields of a
tagged response union nullable while keeping referenced write schemas intact.

```yaml
x-moonbit-paginate: {kind: page, param: page, items: result, next: result_info.total_pages}
```

Numbered pages begin at the query page or page one and preserve the other
filters, including per-page size. The reported total page count ends the
iterator. Without a total, an empty result ends it.

The retry table can include `guard_response_retries` method/status rules.
They keep a positive server override inside a response-replay boundary for
selected methods. Transport decisions still follow the retry policy.
`rate_limit_prefix` may give several modules a shared provider prefix.

For generated type names, `x-moonbit-strip-type-prefixes` lists schema
namespace prefixes that can drop when the shortened declaration is unique.
A collision keeps the original name and produces a census note. A schema's
`x-moonbit-type-name` supplies an explicit MoonBit declaration name. Envelope
schemas and metadata reachable only from the wire wrapper are omitted from
the public vocabulary. The raw reply still preserves them.

Multipart clients label required parts and choose a boundary absent from
the complete bytes of every buffered part. The builder collects conflicts in
one scan per part before choosing the first free suffix. `x-moonbit-parameter-name` on a
multipart field changes the MoonBit argument label while retaining the part's
wire name. Vocabulary-only generators still accept a caller-provided boundary.
A ledger entry with `legacy_multipart_boundary = true` preserves an existing
client's explicit boundary argument.

A client gets the generic SSE method when a selected operation declares an
SSE success medium or selects the typed SSE adapter. Existing clients can
pin `legacy_generic_stream = true` in the ledger to preserve their interface.
