# Mere on Cloudflare Workers

Minimal template for shipping a Mere program to Cloudflare Workers.
5.7 KB compiled wasm, no npm dependencies at runtime, cold start ~ms.

## What's here

- `main.mere` — Mere source. Registers a fetch handler via
  `cf_on_fetch`. Receives JSON-encoded HTTP request, returns
  JSON-encoded response.
- `worker.js` — Cloudflare Worker entry (ES module). Loads
  `main.wasm`, provides the `cf_on_fetch` extern and the standard
  prelude stubs, marshals `Request` ↔ JSON ↔ Mere closure.
- `wrangler.toml` — Cloudflare Worker deployment config.
- `build.sh` — compiles `main.mere` → `main.wat` → `main.wasm`.
- `local_test.js` — Node-based smoke test that mimics CF's
  `fetch(request)` shape without wrangler / miniflare.

## Building

```
sh build.sh
```

Produces `main.wasm` (~6 KB).

## Local smoke test

```
node local_test.js
```

Expected output — three requests, each returning
`hello from Mere on Cloudflare — <METHOD> <PATH>`:

    --- GET / ---
    status: 200
    headers: { 'content-type': 'text/plain' }
    body: hello from Mere on Cloudflare — GET /

    --- GET /hello?name=world ---
    status: 200
    ...
    body: hello from Mere on Cloudflare — GET /hello?name=world

    --- POST /submit ---
    status: 200
    ...
    body: hello from Mere on Cloudflare — POST /submit

## Deploying to Cloudflare

Prerequisites: `wrangler` CLI (`npm install -g wrangler`), a
Cloudflare account with Workers enabled, and `wrangler login`
completed once.

```
sh build.sh
wrangler deploy
```

`wrangler dev` runs the same code locally in a V8 isolate identical
to production (via miniflare):

```
wrangler dev            # → http://localhost:8787
```

## The Mere ↔ CF Worker protocol

Cloudflare Workers give you a per-request `Request` object and
expect a `Response` back. Between JS and Mere we serialize as JSON:

**Request JSON** (built by `worker.js` from the incoming `Request`):

```
{
  "method":  "GET",
  "path":    "/hello?name=world",
  "headers": { "content-type": "text/plain", ... },
  "body":    ""
}
```

**Response JSON** (returned by the Mere closure):

```
{
  "status":  200,
  "headers": { "content-type": "text/plain" },
  "body":    "hello from Mere"
}
```

The Mere program can parse the request with `contrib/json/json.mere`
and build the response with `contrib/json/writer.mere` for anything
richer than the string-scan approach used in `main.mere`.

## What DOESN'T work on Cloudflare Workers

Cloudflare Workers run in V8 isolates without Node.js APIs. The
following Mere externs are unavailable:

- **TCP** (`tcp_connect` / `tcp_read` / `tcp_write`) — no raw
  sockets. Use `fetch()` for outgoing HTTP instead (a JS
  `fetch`-based extern would need writing).
- **Subprocess** (`subprocess_run`) — no child_process.
- **File I/O** (`read_file` / `write_file`) — no fs. Static assets
  go through the wrangler `[assets]` binding.
- **Worker threads / SharedArrayBuffer** — no `sleep_ms` (Atomics.wait
  isn't allowed on the main isolate loop).

For KV, R2, D1 storage, use CF-provided bindings — those need
CF-specific glue in `worker.js` and can be added incrementally.

## Non-goals for this template

- **KV / R2 / D1 bindings**: skeleton only, add as needed.
- **Durable Objects**: different runtime shape; separate template.
- **Auto-rebuild on `.mere` changes**: run `sh build.sh` manually,
  or wrap in a file watcher.
