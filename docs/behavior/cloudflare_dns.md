# Cloudflare DNS behavior survey

Survey date 2026-11-18. The request and response shapes come from the vendored
OpenAPI at `3680a9d2d4f075407dbcd5723d00325930c3eedd`. The research also
reviewed the more recent `17d9fe006df3de4d6160dff6d55a3dcbc2fe87b4` and the
SDK pins below. The fixtures use synthetic data and the published schema.

## A — Cloudflare's contract

- Cloudflare documents a 429 after exceeding 1,200 requests per five minutes
  per user or token, and a separate 200 requests per second per IP limit.
  It describes the penalty as “all API calls for the next five minutes will be
  blocked”. Its `retry-after` header reports whole seconds rounded up.
  [Cloudflare limits](https://developers.cloudflare.com/fundamentals/api/reference/limits/)
- Cloudflare recommends the bearer token scheme and supports the older
  email plus Global API key credential. Its service key retirement notice
  gives September 30, 2026 as the last working date.
  [Authentication](https://developers.cloudflare.com/fundamentals/api/how-to/make-api-calls/),
  [Global keys](https://developers.cloudflare.com/fundamentals/api/get-started/keys/),
  [Service key retirement](https://developers.cloudflare.com/changelog/post/2026-03-19-service-key-authentication-deprecated/)
- The OpenAPI does not declare an idempotency key for these operations. DNS
  batch changes run in Deletes, Patches, Puts, Posts order inside one database
  transaction. Propagation can complete at different times. Import/export
  have a per-user limit of three requests per minute.
  [Batch changes](https://developers.cloudflare.com/dns/manage-dns-records/how-to/batch-record-changes/),
  [Import and export](https://developers.cloudflare.com/dns/manage-dns-records/how-to/import-and-export/)
- The envelope defines `result`, `success`, `errors`, `messages` and page
  metadata. The typed failure keeps the response head plus bounded raw bytes.
  [OpenAPI envelope definitions](https://github.com/cloudflare/api-schemas/blob/17d9fe006df3de4d6160dff6d55a3dcbc2fe87b4/common.yaml#L30-L131)

## B — Official SDKs and adopted policy

TypeScript v7.4.0 (`0eb9ef0ea40c1fe38e4b19be92f41bd7466bc1d6`), Go v7.15.0
(`d2f77a066fb7efbdb1572d2b0ac52dc4fa248ffb`) and Python v5.10.0
(`f9186cff279be0930e666b047e09823a3b9fc952`) were examined.

| Setting | SDK choice | Basis |
| --- | --- | --- |
| Attempt count | 2 retries after the first attempt | [TypeScript default](https://github.com/cloudflare/cloudflare-typescript/blob/0eb9ef0ea40c1fe38e4b19be92f41bd7466bc1d6/src/client.ts#L309-L352) |
| HTTP responses | GET, HEAD, PUT and DELETE retry 408, 409, 429 and 500–599. POST and PATCH retry 429 only. | [TypeScript retry rules](https://github.com/cloudflare/cloudflare-typescript/blob/0eb9ef0ea40c1fe38e4b19be92f41bd7466bc1d6/src/client.ts#L799-L820) |
| Overrides | `x-should-retry: false` vetoes any response retry. The true value can force a retry within the allowed POST/PATCH status boundary and on other methods, subject to the runtime's budget and replayability. | [Go retry rules](https://github.com/cloudflare/cloudflare-go/blob/d2f77a066fb7efbdb1572d2b0ac52dc4fa248ffb/internal/requestconfig/requestconfig.go#L253-L335) |
| Transport | mttp retries `Refused` and other failures proving the request unprocessed on all methods. It can retry eligible sent transport failures on GET, HEAD, PUT and DELETE. | [mttp contract](https://github.com/gaato/mttp/blob/main/CONTRACT.md) |
| Delay | `retry-after-ms` takes precedence over `retry-after` in seconds or HTTP date. Server waits have no policy cap. Otherwise use 500 ms exponential backoff up to 8 s, with up to 25% subtracted as jitter. | [TypeScript delays](https://github.com/cloudflare/cloudflare-typescript/blob/0eb9ef0ea40c1fe38e4b19be92f41bd7466bc1d6/src/client.ts#L822-L874) |
| Timeouts | 60 s per attempt. A caller-provided total deadline and timer also cover waiting. | [TypeScript timeout](https://github.com/cloudflare/cloudflare-typescript/blob/0eb9ef0ea40c1fe38e4b19be92f41bd7466bc1d6/src/client.ts#L303-L352) |
| Rate-limit bucket | `cloudflare:<operation-id>`. The runtime limiter does not yet consume Cloudflare's `Ratelimit` or `Ratelimit-Policy` headers. | [Cloudflare limits](https://developers.cloudflare.com/fundamentals/api/reference/limits/) |

The official SDKs retry writes after 5xx. This SDK restricts POST and PATCH
response retries to 429 because no idempotency key establishes safe replay.
The positive retry override respects that write boundary. Server-directed
delays follow TypeScript and Go. Python honors at most 60 seconds before
falling back to exponential backoff.
[Python delay handling](https://github.com/cloudflare/cloudflare-python/blob/f9186cff279be0930e666b047e09823a3b9fc952/src/cloudflare/_base_client.py#L758-L814)

Typed methods return the envelope's result. A 2xx carrying `success: false`
returns the same failure type as a 4xx. Earlier termination at
`result_info.total_pages` saves the extra request that the official page
iterator needs when it only checks for an empty result.
[TypeScript page iterator](https://github.com/cloudflare/cloudflare-typescript/blob/0eb9ef0ea40c1fe38e4b19be92f41bd7466bc1d6/src/core/pagination.ts#L19-L45)

## C — Community evidence

octoDNS records that some 429 replies have no body or carry non-JSON text.
Those failures keep their raw bytes and return empty decoded message arrays
when the envelope is absent.
[octodns-cloudflare](https://github.com/octodns/octodns-cloudflare/blob/a3817e916a83fdec2b679791f4420a4932e759e3/octodns_cloudflare/__init__.py#L211-L290)

## Fixture provenance

The offline fixtures construct DNS and Zones responses from the pinned OpenAPI.
They use example.com names, documentation IP addresses and fake credentials.
The opt-in native smoke test in `runtime-tests/src/cloudflare_dns_live` reads
`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ZONE_ID` from its process environment
and skips when either is absent. Its two requests only list zones and records.
