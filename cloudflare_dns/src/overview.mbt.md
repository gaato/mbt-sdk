# gaato/cloudflare_dns

Cloudflare v4 REST client for zones, DNS records, DNSSEC, and zone-level DNS
settings. It supports MoonBit's wasm-gc, JavaScript and native targets.
For code that runs in Cloudflare Workers and needs runtime bindings, see
[mizchi/cloudflare](https://mooncakes.io/docs/mizchi/cloudflare).

## Install

```sh
moon add gaato/cloudflare_dns
moon add gaato/mttp_core
moon add gaato/mttp
```

An app adds all three: `gaato/mttp` for its backend and clock, `gaato/mttp_core`
for the `client.Client` the examples take. A library that wraps this SDK adds
`gaato/cloudflare_dns` and `gaato/mttp_core`, and takes the backend from its
caller.

Import `gaato/cloudflare_dns`, `gaato/cloudflare_dns/gen` for the data types
and low-level builders, and `gaato/mttp_core/client` if you pass a runtime
client. Create a [Cloudflare API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
with Zone Read and DNS Read on the zones you intend to list. Add DNS Write
for record changes. Pass the token with `ApiToken(token)`. Existing global
keys use `GlobalApiKey(email~, key~)`. Keep the runtime client's default
headers credential-free and supply the credential through `auth`.

```mbt check
///|
pub async fn list_zone_records(
  runtime : @client.Client,
  token : String,
) -> Unit {
  let dns = @cloudflare_dns.CloudflareDns::from_client(
    runtime,
    auth=ApiToken(token),
  )
  match dns.list_zones(name="example.com") {
    Ok([zone, ..]) =>
      match
        dns.list_dns_records(zone_id=zone.id, name_endswith=".example.com") {
        Ok(records) => println(records.length())
        Err(error) => println(@debug.to_string(error))
      }
    Ok(_) => println("Zone not found")
    Err(error) => println(@debug.to_string(error))
  }
}
```

`CloudflareDns::new(backend, clock, auth=ApiToken(token))` configures defaults
over a backend and clock you supply. `from_client` uses the lifetime and
policies of your supplied runtime.

## Add or change records

```mbt check
///|
pub async fn add_records(
  dns : @cloudflare_dns.CloudflareDns,
  zone_id : String,
) -> Result[@gen.DnsBatchResult, @cloudflare_dns.Failure] {
  let web = @gen.ARecord::new(
    name="www.example.com",
    content="192.0.2.1",
    ttl=300,
  )
  let mail = @gen.MXRecord::new(
    name="example.com",
    content="mx.example.com",
    priority=10,
  )
  let note = @gen.TXTRecord::new(
    name="_verify.example.com",
    content="\"verification\"",
  )
  match dns.create_dns_record(zone_id~, A(web)) {
    Err(error) => Err(error)
    Ok(_) =>
      dns.batch_dns_records(
        zone_id~,
        @gen.DnsBatch::new(posts=[MX(mail), TXT(note)]),
      )
  }
}
```

Use `edit_dns_record` for PATCH and `update_dns_record` for PUT. The record
constructor selects the wire `type`. New response types can be matched as
`Unknown(type, json)`. Batch requests accept `deletes`, `patches`, `puts` and
`posts` in one transaction. Changes propagate individually. The batch limit
is 200 records per action on Free and 3,500 per action on paid plans.
[Cloudflare batch record changes](https://developers.cloudflare.com/dns/manage-dns-records/how-to/batch-record-changes/)

## Import and export BIND

```mbt check
///|
pub async fn transfer_bind(
  dns : @cloudflare_dns.CloudflareDns,
  zone_id : String,
  zone_file : String,
) -> Result[String, @cloudflare_dns.Failure] {
  match dns.import_dns_records(zone_id~, zone_file~, proxied=false) {
    Ok(_) => dns.export_dns_records(zone_id~)
    Err(error) => Err(error)
  }
}
```

Import chooses a multipart boundary absent from the submitted parts.
It accepts up to 256 KiB and export returns UTF-8 text. Cloudflare limits these
endpoints to three requests per minute per user.
[Cloudflare BIND import and export](https://developers.cloudflare.com/dns/manage-dns-records/how-to/import-and-export/)

## Pages, errors and deadlines

`list_zones` and `list_dns_records` each return a single page. The
`_pages` methods take the same filters and return a paginator. Call
`next_page()` until it returns `Ok(None)`. The paginator uses
`result_info.total_pages` when supplied and otherwise stops at an empty
page. For the full response including the five `result_info` fields, use
`send` with the corresponding request builder from `gaato/cloudflare_dns/gen`.

`delete_zone` returns `Ok(None)` when Cloudflare sends a null or omitted
result. Other methods that decode a result require a non-null payload.
Fields represented by `Presence` distinguish an omitted field from an
explicit null.

HTTP errors and JSON responses with `success: false` return `Failure::Http`.
Its response head includes the status and headers. The two message arrays
include codes, descriptions and available documentation links or source
pointers. The failure retains up to 1 MiB of response bytes, including when a
429 has an empty body or a proxy returns text. `Failure::Decode` covers bad
success payloads, `Failure::Transport` covers transport errors, and
`Failure::Validation` covers invalid request headers.

The default retry policy allows two retries and a 60-second per-attempt
timeout. HTTP 429 honors the server's `Retry-After`, so a call can wait for
minutes between attempts. Cancel the task running the call to interrupt the
wait when using a cancellation-aware clock such as mttp's async clock. Supply a
timer and `total_timeout_ms` for a whole-call deadline that includes waits.
Cloudflare also applies per-token and per-IP limits across operations.
[Cloudflare API limits](https://developers.cloudflare.com/fundamentals/api/reference/limits/)

## License

Apache-2.0
