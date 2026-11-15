# gaato/replicate

Generated API vocabulary for replicate in MoonBit. This scaffold provides request
builders and JSON types in `gaato/replicate/gen`; a client facade is pending.

## Install

```sh
moon add gaato/replicate
```

Import `gaato/replicate/gen` to use the generated operations. Prepare JSON values with
MoonBit's built-in JSON support:

```mbt check
///|
test {
  let body : Json = { "example": true }
  ignore(body)
}
```

## Limits and errors

The caller supplies a transport and handles errors, retries and timeouts.
Non-JSON responses remain raw HTTP responses. The vocabulary supports wasm-gc,
JavaScript and native targets; transport support depends on the chosen backend.
See the [behavior survey](https://github.com/gaato/mbt-sdk/blob/main/docs/behavior/replicate.md) for policy work
still to be completed and the [specification source](https://api.replicate.com/openapi.json).
