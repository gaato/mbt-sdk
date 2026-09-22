# mbt-sdk

Foundation for MoonBit SDKs: a sans-IO HTTP vocabulary (`http/`), transport adapters (`http-async/`), later a client runtime and a generator. Design and public API spec: `docs/design.md`. Treat that spec as the contract: do not add public API that is not in it; if something is unclear or seems wrong, stop and report instead of guessing.

## Layout rules

- `http/` (module `gaato/http`) must stay dependency-free: no `import` block in `http/moon.mod`, only `moonbitlang/core/*` in its `moon.pkg` files. It must check on wasm-gc, native and js.
- Anything needing `moonbitlang/async` goes in `http-async/` (imports are module-wide in MoonBit).
- Target differences are expressed with `options(targets: {...})` in `moon.pkg`, not with ad-hoc conditionals.

## Code rules

- Follow the `moonbit-agent-guide` skill.
- Every public item has a `///|` doc comment; add a ```` ```mbt check ```` example where it can run without IO.
- Black-box tests in `*_test.mbt`, white-box tests in `*_wbtest.mbt`.
- Do not suppress the `implicit_impl_as_method` warning. If a trait method must be callable with dot syntax, declare `pub extend T with Trait::{method}` explicitly.
- `pkg.generated.mbti` files are committed. Run `moon info` after changing public API.
- Delete the `placeholder.mbt` of a package when you add its real code, and drop unused imports from its `moon.pkg`.

## Gates (must all pass; run from the repo root)

`scripts/gates.sh` runs the whole list below (`--no-native-tests` where sockets are forbidden, `--no-js` without Node). `scripts/generate.sh --check` verifies the overlays and the generated code.

```sh
moon -C http check --deny-warn --target wasm-gc
moon -C http check --deny-warn --target native
moon -C http check --deny-warn --target js
moon -C http test --target wasm-gc
moon -C http test --target native
moon -C http test --target js
moon -C http-async check --deny-warn --target native
moon -C http-async check --deny-warn --target js
moon -C http-async test --target native
moon -C http-async test --target js      # socket-free async tests only
moon -C sdk-runtime check --deny-warn --target wasm-gc
moon -C sdk-runtime check --deny-warn --target native
moon -C sdk-runtime check --deny-warn --target js
moon -C sdk-runtime test --target wasm-gc
moon -C sdk-runtime test --target native
moon -C sdk-runtime test --target js
moon -C openai check --deny-warn --target wasm-gc
moon -C openai check --deny-warn --target native
moon -C openai check --deny-warn --target js
moon -C openai test --target wasm-gc
moon -C openai test --target native
moon -C openai test --target js
moon -C openai check src/gen --deny-warn --target wasm-gc
moon -C openai check src/gen --deny-warn --target native
moon -C openai check src/gen --deny-warn --target js
moon -C openai test src/gen --target wasm-gc
moon -C openai test src/gen --target native
moon -C openai test src/gen --target js
moon -C anthropic check --deny-warn --target wasm-gc
moon -C anthropic check --deny-warn --target native
moon -C anthropic check --deny-warn --target js
moon -C anthropic test --target wasm-gc
moon -C anthropic test --target native
moon -C anthropic test --target js
moon -C fixtures/gen/badhttp check --deny-warn --target wasm-gc
moon -C fixtures/gen/badhttp check --deny-warn --target native
moon -C fixtures/gen/badhttp check --deny-warn --target js
moon -C fixtures/gen/petstore3 check --deny-warn --target wasm-gc
moon -C fixtures/gen/petstore3 check --deny-warn --target native
moon -C fixtures/gen/petstore3 check --deny-warn --target js
moon -C runtime-tests check --deny-warn --target native
moon -C runtime-tests check --deny-warn --target js
moon -C runtime-tests test --target js
moon -C runtime-tests test --target native     # runs loopback socket tests of other members too; needs socket permission
.venv/bin/python tools/apply_overlay.py openai/spec/openai.yaml openai/spec/openai.patched.json openai/overlays/*.yaml
.venv/bin/python -m unittest discover -s tools/gen/tests -v
.venv/bin/python tools/gen/main.py --spec openai/spec/openai.yaml --overlay openai/overlays/moonbit.yaml --out openai/src/gen --package gaato/openai/gen --check
.venv/bin/python tools/gen/census.py specs/badhttp/openapi.json badhttp --expect-zero
.venv/bin/python tools/gen/census.py specs/petstore3/openapi.json petstore3 --expect-zero
.venv/bin/python tools/gen/census.py openai/spec/openai.yaml openai --derive-operation-ids --overlay openai/overlays/fix.yaml --overlay openai/overlays/moonbit.yaml --expect-zero
scripts/generate.sh --check
moon fmt --check
moon info
```

Generator census の診断ゼロを要求するのは、上記の badhttp / petstore3 全操作、`fix.yaml` と `moonbit.yaml` を適用した OpenAI 全操作、および `scripts/generate.sh --check` が生成する OpenAI include 済み閉包。型を特定できない schema を暗黙に `Json` へ落としてはならず、raw JSON は overlay の明示的な `x-moonbit-json: true` がある場合だけ許可する。次の upstream OpenAI と OpenRouter の census は数を `docs/census.md` に記録する report-only コマンドであり、`--expect-zero` を付けない。

```sh
.venv/bin/python tools/gen/census.py openai/spec/openai.yaml openai --derive-operation-ids
.venv/bin/python tools/gen/census.py specs/openrouter/openapi.json openrouter --ops createMessages,createResponses,getModels,createEmbeddings
.venv/bin/python tools/gen/census.py specs/openrouter/openapi.json openrouter
```

Loopback socket tests live in `http-async/src/loopback` (native only). They need permission to open sockets on 127.0.0.1; a sandbox that forbids sockets cannot run them, so say so instead of reporting them as passed.

`runtime-tests/src/badhttp` talks to the public https://badhttp.dev (opt-in, `scripts/conformance.sh`, needs the network, ~30 requests against a 100-per-10-s limit). It is not a gate; do not add it to CI.

`runtime-tests/src/live` talks to the real OpenAI and OpenRouter APIs (opt-in, `scripts/live.sh`, needs the network and provider keys). It is never a gate; do not add it to CI or run it without explicit authorization.

## Hard limits for agents

- Do not run jj or git. Do not publish. Do not create anything on GitHub. Network use is limited to `moon update` / `moon add`.
- No browser, dev server or computer-use. Verification is the gate commands only.
- No long-blocking commands: every test that opens a socket must have a timeout.
