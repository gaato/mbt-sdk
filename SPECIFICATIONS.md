# Specifications

The external documents the hand-written modules implement, how far, and where
they depart from them. Statuses were checked on 2026-10-21 against the RFC
Editor and the IETF datatracker. A row names the file and function that
implement the document, so a change to either can be checked against it.

The compression formats behind `Content-Encoding` (RFC 1950, 1951, 1952, 7932,
8878, 9659) are implemented by the decoder modules, not here; their status and
errata are tracked in
[codecs.mbt's CONTRACT.md](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md#specifications).
`http-async/src/content_coding.mbt` only reads the coding names (RFC 9110
§8.4).

## Documents

| Document | Status | Implemented in | What is implemented |
|---|---|---|---|
| RFC 9110, HTTP Semantics | Internet Standard (STD 97) | `http/src/redirect.mbt`; `http/src/retry_after.mbt`; `http/src/idempotent.mbt`; `http-async/src/content_coding.mbt`, `request_body.mbt`, `proxy.mbt` | Redirects (§15.4), `Retry-After` and HTTP-date (§10.2.3, §5.6.7), idempotent methods (§9.2.2), content codings (§8.4), `Content-Length` (§8.6), `CONNECT` (§9.3.6) |
| RFC 9112, HTTP/1.1 | Internet Standard; updated by RFC 9931, which this code does not use | `http-async/src/proxy.mbt` | The absolute-form request target through a forward proxy (§3.2.2). Message framing is moonbitlang/async's |
| RFC 3986, URI Generic Syntax | Internet Standard (STD 66); updated by RFC 7320, 8820 | `http/src/url.mbt` (`Url::parse`, `Url::resolve`, `percent_encode`); `http/src/redirect.mbt` | Parsing, strict reference resolution (§5.2), `remove_dot_segments` (§5.2.4), recomposition (§5.3). `sdk-runtime`'s base-URL join (`client.mbt`, `resolve_url`) is deliberately not §5.2: it appends to the base path |
| RFC 5952, IPv6 text representation | Proposed Standard; updates RFC 4291 | `http/src/ipv6.mbt` (`ipv6_text`) | The canonical form of IPv6 hosts (§4, §5) |
| RFC 4291, IPv6 addressing | Draft Standard; updated by RFC 5952, 6052, 7136, 7346, 7371, 8064 | `http-async/src/no_proxy.mbt` | IPv6 addresses and prefixes in `NO_PROXY` |
| draft-ietf-httpbis-rfc6265bis-22, Cookies | Internet-Draft, revision 22, in the RFC Editor queue; will obsolete RFC 6265 | `http/src/cookie/` (`parse_set_cookie`, `parse_cookie_date`, `domain_match`, `path_match`, `CookieJar`) | Date parsing (§5.1.1), domain- and path-match (§5.1.3, §5.1.4), the prefixes (§5.4), the 400-day lifetime cap (§5.5), `Set-Cookie` parsing (§5.6), the storage model (§5.7), the `Cookie` header (§5.8.3), checked against the http-state tests in `conformance/src/cookie` (the 33 that predate the draft or are disabled upstream are named and counted). Two steps of §5.7 differ: step 18, which refuses cookies from cross-site requests, does not apply to a client, and step 21's `__Host-` cookie needs a `Path=/` attribute, not one that falls back to a default path of `/`, as Chromium does |
| RFC 6265, HTTP State Management | Proposed Standard; obsoletes RFC 2965 | `http/src/cookie/jar.mbt` | Superseded here by 6265bis-22; the default caps of 50 cookies per domain and 3000 in all are its §6.1 minimums |
| RFC 8288, Web Linking | Proposed Standard; obsoletes RFC 5988 | `http/src/link.mbt` (`parse_link_next`) | Only the target of `rel="next"`, unresolved, from the first `rel` parameter (§3.3); target attributes (Appendix B.2 steps 15–16) are not parsed |
| RFC 7578, multipart/form-data | Proposed Standard; obsoletes RFC 2388 | `http/src/multipart/` | Part framing (§4.1), `Content-Disposition` with `name` and `filename` (§4.2) |
| RFC 2046, MIME media types | Draft Standard; updated by RFC 2646, 3798, 5147, 6657, 8098 | `http/src/multipart/multipart.mbt` (`is_boundary_char`, `validate_boundary`) | Boundary characters and length (§5.1.1) |
| RFC 7617, Basic authentication | Proposed Standard; obsoletes RFC 2617 | `http-async/src/proxy.mbt` (`basic_credentials`) | `Proxy-Authorization: Basic` from a proxy URL's userinfo |
| RFC 6750, Bearer tokens | Proposed Standard; updated by RFC 8996, 9700 | `sdk-runtime/src/auth.mbt` | `Authorization: Bearer` |
| RFC 9535, JSONPath | Proposed Standard | `tools/apply_overlay.py`, through the `jsonpath-rfc9535` library | Overlay action targets |
| WHATWG HTML, §9.2 Server-sent events | Living Standard | `http/src/sse/parser.mbt` (`SseParser`) | Interpreting an event stream (§9.2.6), checked against the streams of web-platform-tests' eventsource/format tests in `conformance/src/sse`. Reconnection and `Last-Event-ID` are not implemented |
| WHATWG URL Standard | Living Standard | `http/src/url.mbt`; `http/src/form.mbt`; `http/src/cookie/domain.mbt` | Percent-encode sets, input trimming, the urlencoded serializer and parser, the "ends in a number" rule for IP hosts. URLs are otherwise RFC 3986's; see "Conventions" |
| WHATWG Encoding Standard | Living Standard | `http/src/utf8.mbt`; `jsonrpc/src/utf8.mbt` | UTF-8 encoding, a lone surrogate becoming U+FFFD |
| WHATWG Fetch Standard | Living Standard | `http/src/redirect.mbt`; `http/src/body.mbt` | The redirect method rewrite and header stripping; which bodies can be replayed |
| WHATWG HTML, multipart/form-data encoding algorithm | Living Standard | `http/src/multipart/multipart.mbt` (`append_escaped_parameter`) | `"`, CR and LF in `name` and `filename` become `%22`, `%0D`, `%0A` |
| JSON-RPC 2.0 | jsonrpc.org specification | `jsonrpc/src/message.mbt`, `types.mbt` | Requests, notifications, responses and the standard error codes, in a strict (`"jsonrpc":"2.0"`) and a bare envelope. Batches are refused |
| NDJSON | No specification | `jsonrpc/src/framer.mbt` (`LineFramer`) | One JSON message per LF-terminated line, a CR before the LF dropped |
| JSON Schema draft-07 | Internet-Draft (expired), as published at json-schema.org | `tools/gen/codex.py` | The Codex app-server schema (`codex-protocol/spec/schema.json`) |
| OpenAPI 3.0 and 3.1 | 3.0.4 and 3.1.2 are the latest of each line; 3.2.1 is the latest | `tools/gen/` | Inputs: GitHub 3.0.3, OpenAI 3.0.0, Anthropic and OpenRouter 3.1.0. Both schema dialects are read (`nullable`, and `type` arrays). The `openapi` field is not checked |
| OpenAPI Overlay 1.0.0 | 1.2.0 is the latest | `tools/apply_overlay.py` | The `update` and `remove` actions. 1.1.0's `copy` is not implemented; every overlay declares `overlay: 1.0.0` |

## Errata

Technical errata that touch a section the code implements, and which reading
the code follows. Errata to sections the code does not implement are left out.

| Erratum | Status | The code |
|---|---|---|
| RFC 6265 4148, §5.1.1: the non-digit tail of a date token is optional | Verified | Follows it: `ends_number` also accepts the end of the token (`cookie/date.mbt`) |
| RFC 6265 8877, §5.1.1: month names are case-insensitive | Reported | Follows it: `parse_month` lower-cases first |
| RFC 6265 6093, §3: Set-Cookie fields are not combined | Verified | Follows it: `CookieJar::store` reads each field line with `get_all` and never splits on commas (`cookie/jar.mbt`) |
| RFC 6265 7604, §3: ignore Set-Cookie in 1xx responses | Verified | Not reachable: transports do not hand 1xx responses up |
| RFC 6265 3663, §5.1.4: "identical" paths | Held for Document Update | The original text: `path_match` compares the paths byte for byte, escapes as written |
| RFC 3986 4547, §5.4.2: excess `..` segments | Held for Document Update | The original text: `../../../g` against `http://a/b/c/d;p?q` is `http://a/g` (`url_test.mbt`) |
| RFC 3986 4789, §5.2.3: merging with a base ending in `/..` | Held for Document Update | The original algorithm (`merge_paths`) |
| RFC 3986 4942, §3.2.2: reg-name without sub-delims | Held for Document Update | The original text: `reg_name` accepts sub-delims |
| RFC 3986 9147, §2.3: backslash as unreserved | Reported | Not followed: a backslash is percent-encoded, as `Url::parse` documents |
| RFC 3986 5428, §4.2: relative-part and path-abempty | Held for Document Update | No change in behaviour; `//g` parses as a network-path reference |
| RFC 9110 7109, §15.4.9: 308 does not change the method | Verified (editorial) | Follows it: only 301, 302 and 303 rewrite the method (`redirect_method`) |
| RFC 8288 9091, §3: relation types are compared case-insensitively | Reported | Follows it (`parse_next_link`) |
| RFC 8288 5878, Appendix B.2 steps 15–16 | Verified | Not applicable: target attributes are not parsed |
| RFC 5952 6272, §4.2.1 against §4.2.2 | Held for Document Update | Consistent with it: only runs of two or more zero groups become `::` (`ipv6_text`) |
| RFC 4291 6596, §2.2: `::` must not stand for one group | Held for Document Update | Accepted on input, as RFC 3986's grammar allows; printed uncompressed (`ipv6_wbtest.mbt`) |
| RFC 7617 9174, §2: control characters in credentials | Reported | Not followed: `basic_credentials` neither rejects control characters nor a percent-decoded `:` in the user-id |
| RFC 7578 4676, §4.6: delimiters in the example | Verified | Follows it: each part opens with `--boundary` CRLF and the body ends with `--boundary--` CRLF |
| RFC 2046 6776, §5.1.1: the CRLF before the first delimiter | Held for Document Update | The body starts with `--boundary`; the collision check reads each part body as if a CRLF preceded it (`boundary_scan.mbt`) |

## Conventions

Where no document applies, or the code follows widely used clients rather than
a document:

| Behaviour | Followed | Where |
|---|---|---|
| `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` | curl, Go and httpx: lower-case name first, an empty value unset, `ALL_PROXY` as the fallback; `NO_PROXY` as curl reads it, plus CIDR and `host:port` entries and Go's `*.domain` (which, unlike Go, also covers the domain itself, as a leading dot does in curl); upper-case `HTTP_PROXY` ignored when `REQUEST_METHOD` is set (httpoxy, CVE-2016-5385) | `http-async/src/proxy.mbt`, `no_proxy.mbt` |
| `retry-after-ms` | The OpenAI SDKs: milliseconds, preferred over `Retry-After` | `http/src/retry_after.mbt` (`retry_after_ms`) |
| Decimal seconds in `Retry-After` | The OpenAI SDKs parse it as a float; RFC 9110's `delay-seconds` is `1*DIGIT` | `http/src/retry_after.mbt` (`parse_retry_after`) |
| `x-should-retry` | The Stainless-generated SDKs | `sdk-runtime/src/retry.mbt` |
| Method names in any case | RFC 9110 §9.1 makes method names case-sensitive, but `AsyncTransport` sends a standard method in any case as its canonical upper-case form (moonbitlang/async's `RequestMethod`), so the code that decides on the method follows what goes on the wire: `is_idempotent`, `redirect_method` and the transport's replay check ignore case | `http/src/idempotent.mbt`; `http/src/redirect.mbt`; `http-async/src/pool.mbt` (`replayable`), `transport.mbt` (`request_method`) |
| `x-ratelimit-*` | Each API's documentation, configured per SDK | `sdk-runtime/src/rate_limit.mbt` (`rate_limit_headers`); `github/src/client.mbt` |
| URLs | RFC 3986, not the WHATWG URL parser, though with WHATWG's percent-encode sets and input trimming. Where the two differ: non-ASCII and percent-encoded hosts are refused (no IDNA), as are hosts with characters outside `reg-name`; a backslash is data; `http:x` and `http:/x` have no authority, and a reference with the base's scheme is not made relative (§5.2.2 strict); a host that ends in a number but is not four decimal octets is a `reg-name`; an IPv6 address keeps a dotted IPv4 tail (RFC 5952 §5); `%2e` is not a dot segment; an empty userinfo or password is kept; an empty path is kept as written (RFC 9110 §4.2.3 makes it equivalent to `/`); `'` in a query is not encoded, so a relative reference encodes as its resolution does; an empty host parses, and RFC 9110 §4.2.1's refusal of it is made where a URL becomes a request target (`redirect_target`, the proxy settings). `conformance/src/url` checks every other http, https, ws and wss row of web-platform-tests' urltestdata.json, and its urlencoded parser table against `query_params` | `http/src/url.mbt`; `http/src/redirect.mbt`; `http-async/src/proxy.mbt` |
| JSON-RPC `"id": null` and `"params": null` | JSON-RPC 2.0 §4.1 makes a notification a request without an `id` member, so `"id": null` is a request with a null id; null params are kept as given, though §4.2 asks for a structured value. go.lsp.dev/jsonrpc2's vectors read both otherwise; `conformance/src/jsonrpc` checks the rest of them | `jsonrpc/src/message.mbt` |
| A download labelled `Content-Encoding: gzip` | Decoded as labelled (RFC 9110 §8.4), even when `Content-Type` says the file is gzip; a caller that wants the bytes as sent sets `Accept-Encoding` itself, and `AsyncTransport` then undoes no coding | `http-async/src/content_coding.mbt` |
| An event stream's `Content-Type` | `@sse.each_event` parses whatever body it is given; a browser's EventSource refuses anything but `text/event-stream` | `http/src/sse/stream.mbt` |

## Known deviations

Places where the code departs from a document it claims to follow, to be
fixed, each in a row of a table here that its fix removes. None are known.
