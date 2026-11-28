# contrib/http — HTTP server bindings, middleware, and servers

A handful of `extern fn`s that let a Mere program accept HTTP requests
and return responses, plus the middleware and helpers built on them.
Sibling of `contrib/dom` for the server side.

It started as the "Stage A" backend demo — a Mere program compiled to
Wasm, running under `node` via a small glue module. The same externs
are now also implemented natively by the C backend (`mere -c`), so the
same handler builds into a standalone binary. On top of the C
backend's socket builtins (`tcp_listen` / `tcp_accept` / …),
`serve_mt.mere` and `serve_rd.mere` are concurrent servers written in
Mere itself.

## Files

| file | content | lines |
|---|---|---|
| `http.mere` | the core externs: `http_serve`, `http_current_body`, `http_set_status`, `http_set_content_type`, `http_set_header`, `http_get_header` | ~75 |
| `http.glue.js` | CommonJS module exporting `makeHttpGlue()` — the Node host side | ~340 |

Everything else is optional and imported on its own. Unless noted, a
file is pure Mere or uses only externs both hosts implement.

| file | exports | lines |
|---|---|---|
| `router.mere` | `route` / `route_pattern` (`:capture`) / `route_prefix` → `router routes not_found`; `req_path`, `parse_int_or_zero` | ~200 |
| `query.mere` | `split_url`, `parse_query`, `query_get`, `encode_query`, `url_decode` / `url_encode` | ~150 |
| `json_body.mere` | flat-JSON-object body parsing: `parse_json_body`, `json_get`, `body_field` | ~160 |
| `multipart.mere` | `multipart/form-data`: `boundary_from_content_type`, `parse_multipart` | ~150 |
| `cookie.mere` | `cookie_get`, `session_id` | ~40 |
| `escape.mere` | `json_escape`, `jstr`, `html_escape`, `xml_escape`, `cdata_escape` | ~75 |
| `session.mere` | in-memory cookie sessions: `session_new_store`, `session_current`, `session_login`, `session_logout`, `session_require` | ~110 |
| `csrf.mere` | synchronizer-token CSRF: `csrf_new_store`, `csrf_token_for`, `csrf_validate`, `csrf_hidden_input` | ~95 |
| `csrf_field.mere` | `csrf_hidden_field` — the same hidden input as a `contrib/html/build.mere` node, so the token is escaped by `render` | ~15 |
| `basic_auth.mere` | RFC 7617 Basic Auth: `with_basic_auth`, `with_basic_auth_pred` | ~85 |
| `cors.mere` | `with_cors` (preflight short-circuit) | ~55 |
| `security.mere` | `with_security_headers`, `with_hsts` | ~55 |
| `cache.mere` | `cache_immutable` / `cache_private` / `cache_no_store`, `etag`, `if_none_match` | ~70 |
| `ratelimit.mere` | fixed-window limiter: `rate_new`, `rate_over_limit`, `rate_bump`, `rate_reset` | ~85 |
| `access_log.mere` | `with_access_log` — one JSON line per request | ~80 |
| `metrics.mere` | Prometheus text format: `metric_declare_counter` / `_gauge`, `metric_inc` / `metric_add` / `metric_set`, `metrics_render`, `metrics_handler`, `with_metrics` | ~175 |
| `rescue.mere` | `with_rescue` / `with_rescue_ctx` — a failing handler becomes a 500 instead of ending the process | ~55 |
| `arena.mere` | `with_arena` — release a request's allocations when the response is sent | ~35 |
| `mount.mere` | `type mount` (`MExact` / `MPattern`, each with an `acl`), `entries` (→ `router`), `manifest` — one list for routes and their authorization, so the two cannot drift | ~60 |
| `static.mere` | `serve_static_fallback prefix root handler`, `mime_of` | ~110 |
| `client.mere` | outbound HTTP: `http_get`, `http_post_json`, `http_fetch_h`, `http_get_bearer` (Node host, via `curl`) | ~85 |
| `stream.mere` | `http_stream_start` / `http_stream_write` — streamed response body (Node host) | ~25 |
| `sse.mere` | `sse_broadcast`, `sse_bridge_from_redis` — server-sent events through the Node glue | ~50 |
| `sse_native.mere` | `sse_start` / `sse_subscribe` / `sse_publish` — server-sent events with no JS host (C backend, with `serve_mt`) | ~195 |
| `websocket.mere` | `ws_broadcast`, `ws_client_count` — a WebSocket hub terminated by the Node glue | ~45 |
| `tls.mere` | `http_serve_tls port cert key handler` — HTTPS. Separate so that only programs importing it link OpenSSL | ~35 |
| `serve_mt.mere` | `http_serve_mt port workers handler`, `http_serve_mt_ctx` (per-worker state) — a worker pool written in Mere (C backend) | ~320 |
| `serve_mt_tls.mere` | `http_serve_mt_ctx_tls` — the worker pool terminating TLS | ~30 |
| `serve_rd.mere` | `http_serve_rd port workers handler`, `http_serve_rd_ctx` — a readiness loop for the I/O and workers for the handlers, with keep-alive (C backend) | ~450 |

Each file's header comment says what it is for, how it is used, and
what it does not do.

## API

| fn | signature | maps to |
|---|---|---|
| `http_serve` | `int -> (str -> str) -> unit` | `http.createServer((req, res) => …).listen(port)` |
| `http_current_body` | `unit -> str` | request body of the request currently being handled |
| `http_set_status` | `int -> unit` | override the response status for the current request (default `200`) |
| `http_set_content_type` | `str -> unit` | override the `Content-Type` for the current request (default `text/plain; charset=utf-8`) |
| `http_set_header` | `str -> str -> unit` | add or overwrite an arbitrary response header (`Access-Control-Allow-Origin`, `Cache-Control`, `Set-Cookie`, …) |
| `http_get_header` | `str -> str` | read a request header by name (case-insensitive); `""` if absent |

The handler closure receives the request line as `"<METHOD> <URL>"`
(e.g. `"GET /hello"`). Its return value becomes the response body.

If the handler needs the request body (POST / PUT etc.), it calls
`http_current_body ()` from inside the closure. The glue keeps the
body of the in-flight request in a per-request slot; the pointer is
stable for the duration of the handler and overwritten at the start of
the next request.

Status and `Content-Type` follow the same per-request slot pattern.
Defaults are set at the start of each request; call `http_set_status`
/ `http_set_content_type` from inside the handler to override them
before returning the response body.

## Usage

### Mere side

```mere
import "contrib/http/http.mere";

let handle = fn req -> "Hello: " ++ req in
http_serve 8080 handle
```

### Build and run on Node (Wasm)

```sh
dune exec ./bin/mere.exe -- -w examples/http_echo_server.mere > echo.wat
wat2wasm echo.wat -o echo.wasm
node scripts/run_http_server.js echo.wasm
# In another terminal:
curl http://localhost:8080/hello
# → Hello from Mere! You asked: GET /hello
```

`scripts/run_http_server.js` is the reference host — it merges the
`http` glue with the standard Wasm env imports (`puts`, math libc
stubs, etc.) and calls `instance.exports.main()`.

### Build and run natively (C)

```sh
dune exec ./bin/mere.exe -- -c server.mere > server.c
clang -o server server.c
./server
```

The C backend implements the `http.mere` externs itself (a
single-threaded accept loop). For concurrency use `serve_mt.mere` or
`serve_rd.mere`; `scripts/http_concurrency_check.sh` measures it.

## How it works

- `http_serve` receives a port (i32) and a Mere closure. A Mere closure
  is an i32 pointer to a two-word `{ env, fn_idx }` record in the bump
  arena; the glue reads both words with `DataView` (the arena does not
  enforce 4-byte alignment).
- Each incoming request is handled synchronously: Node calls the
  request callback, the callback writes the request line into a
  scratch region of linear memory, dispatches through the exported
  `__indirect_function_table`, reads the returned null-terminated
  string, and sends it back as the response body.
- The scratch offset resets at the start of each request, so returned
  strings never share bytes across requests. The Mere handler runs
  entirely within one JS turn — Node's event loop is what keeps the
  process alive between requests.

The section above describes the Node host. Natively, `http_serve` is
a C accept loop in the emitted runtime, and the request/response
metadata is per-request state in the same way.

## MVP limitations

- **Two hosts, not three**. Node (Wasm) and the C backend implement
  the externs; there is no browser fetch-based variant.
- **The plain handler returns one string**. That string becomes the
  whole response body. Streaming is available per host rather than
  through the handler's return value: `stream.mere`, `sse.mere` and
  `websocket.mere` on Node; `sse_native.mere` natively.
- **Request headers are read one at a time** with `http_get_header`;
  query strings are parsed Mere-side with `query.mere`.
- **Single handler per process** (Node host). Registering multiple servers on
  different ports works, but they all share the scratch buffer.
- **Request body pointer is ephemeral**. `http_current_body ()`
  returns a pointer into a per-request scratch that gets overwritten
  at the start of the next request. If you need to retain the body
  across requests (e.g. store it in a `Map`), copy the bytes into the
  bump arena via a `strbuf`:

  ```mere
  let buf = strbuf_new () in
  let _ = strbuf_push buf (http_current_body ()) in
  let text = strbuf_to_str buf in
  ...
  ```

  See `examples/http_todo_api.mere` for the pattern in context.

## Position

Stage 2 contrib (incubation), sibling of `contrib/dom`. Graduation
target is `mere-http` (separate repo) once the package manager lands.
The lower-level socket layer it once waited for exists as compiler
builtins (`tcp_listen` / `tcp_accept` / `tcp_read` / `tcp_write`,
`io_poll_*`), and `serve_mt.mere` / `serve_rd.mere` are built on it.
