# gaato/cloudflare_dns

Manage Cloudflare DNS from MoonBit through the v4 REST API: list zones, read,
create and change DNS records, batch changes in one transaction, import and
export BIND zone files, and read DNSSEC and zone DNS settings. Use it for a
deploy tool, a dynamic-DNS updater or certificate automation. It runs on
native, JavaScript and Wasm GC.

This module manages DNS from outside Cloudflare. For code that runs inside
Cloudflare Workers and needs runtime bindings, see
[mizchi/cloudflare](https://mooncakes.io/docs/mizchi/cloudflare).

Unofficial, and not affiliated with Cloudflare. A minor release can change the
API; the
[changelog](https://github.com/gaato/moonbit-sdks/blob/main/cloudflare_dns/CHANGELOG.md)
lists each change.

## Install

```sh
moon add gaato/cloudflare_dns
moon add gaato/mttp
```

Import `gaato/cloudflare_dns` and `gaato/cloudflare_dns/gen` (record types
and low-level builders). `gaato/mttp` supplies the network and the clock. Also
add `gaato/mttp_core` if you pass an existing `gaato/mttp_core/client.Client`
to `CloudflareDns::from_client`, or if you write a library that takes the
backend from its caller.

Create a
[Cloudflare API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
with **Zone Read** and **DNS Read** on the zones you need, plus **DNS Write** to
change records. Pass it as `auth=ApiToken(token)`. Older global keys use
`GlobalApiKey(email~, key~)`.

## Find a zone's records

```mbt check
///|
pub async fn count_records(
  dns : @cloudflare_dns.CloudflareDns,
  zone_name : String,
) -> Unit {
  match dns.list_zones(name=zone_name) {
    Ok([zone, ..]) =>
      match
        dns.list_dns_records(zone_id=zone.id, name_endswith="." + zone_name) {
        Ok(records) => println(records.length())
        Err(error) => println(@debug.to_string(error))
      }
    Ok(_) => println("Zone not found")
    Err(error) => println(@debug.to_string(error))
  }
}
```

A command-line program builds the client from mttp's backend and clock, and
closes the backend when it is done. Import `gaato/mttp`, `moonbitlang/core/env`
and `moonbitlang/core/debug` in its `moon.pkg`:

```mbt nocheck
///|
fn main {
  @mttp.run(async fn() {
    guard @env.get_env_var("CLOUDFLARE_API_TOKEN") is Some(token) else {
      println("Set CLOUDFLARE_API_TOKEN")
      return
    }
    let backend = @mttp.backend()
    defer backend.close()
    let dns = @cloudflare_dns.CloudflareDns::new(
      backend,
      @mttp.clock(),
      auth=ApiToken(token),
      timer=@mttp.timer(),
      total_timeout_ms=300_000,
    )
    count_records(dns, "example.com")
  })
}
```

`list_zones` and `list_dns_records` return one page. `list_zones_pages` and
`list_dns_records_pages` take the same filters and return a paginator. Call
`next_page()` until it returns `Ok(None)`.

## Add or change records

The record constructor sets the wire `type`. `batch_dns_records` applies
`deletes`, `patches`, `puts` and `posts` in one transaction.

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

`edit_dns_record` patches selected fields (PATCH), and `update_dns_record`
replaces a record (PUT). A record type this SDK does not know comes back as
`Unknown(type, json)`. Cloudflare limits a batch to 200 records per action on
the Free plan and 3,500 on paid plans.
[Batch record changes](https://developers.cloudflare.com/dns/manage-dns-records/how-to/batch-record-changes/)

## Import and export BIND zone files

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

Import accepts up to 256 KiB, and export returns UTF-8 text. Cloudflare allows
three of these requests per minute per user.

## Errors, retries and deadlines

**Check the `Result` even when the status is 200.** Cloudflare can answer
`success: false` with a 2xx status, and that becomes `Failure::Http` too.

- `Http(...)`: the status and headers, Cloudflare's error and message arrays
  (codes, descriptions, documentation links), and up to 1 MiB of the body.
- `Decode(...)`: a successful response that does not match the model.
- `Transport(...)`: the network failed or a deadline expired.
- `Validation(...)`: invalid input, caught before sending.

| Setting | Default with `CloudflareDns::new` | Notes |
| --- | --- | --- |
| Retries | 2. GET, PUT, DELETE and HEAD on 408, 409, 5xx and network failures; every method, POST and PATCH included, on 429 and when the request was never sent | A 429 honours `Retry-After` however long, which can be minutes. |
| `timeout_ms` | 60 s per attempt | |
| `total_timeout_ms` | none | Set it, with `timer=`, to bound the waits. |

`from_client` keeps the supplied client's policies instead. Cloudflare also
applies per-token and per-IP limits across operations.
[Cloudflare API limits](https://developers.cloudflare.com/fundamentals/api/reference/limits/)

## Links

- [Changelog](https://github.com/gaato/moonbit-sdks/blob/main/cloudflare_dns/CHANGELOG.md)
- [Repository](https://github.com/gaato/moonbit-sdks)

## License

Apache-2.0
