# contrib/http — minimal HTTP server bindings for Node-hosted Mere

One `extern fn` + Node host glue that lets a Mere program compiled to
Wasm accept HTTP requests and return responses. Sibling of
`contrib/dom` for the server side.

This is the "Stage A" backend demo — proof that Mere code can drive
real network traffic today, running under `node` via a small glue
module. A future stage will add a lower-level socket API (`tcp_listen`
/ `tcp_accept` / …) once a C runtime path is in place.

## Files

| file | content | lines |
|---|---|---|
| `http.mere` | one `extern fn http_serve` declaration | ~25 |
| `http.glue.js` | CommonJS module exporting `makeHttpGlue()` | ~100 |

## API

| fn | signature | maps to |
|---|---|---|
| `http_serve` | `int -> (str -> str) -> unit` | `http.createServer((req, res) => …).listen(port)` |
| `http_current_body` | `unit -> str` | request body of the request currently being handled |
| `http_set_status` | `int -> unit` | override the response status for the current request (default `200`) |
| `http_set_content_type` | `str -> unit` | override the `Content-Type` for the current request (default `text/plain; charset=utf-8`) |
| `http_set_header` | `str -> str -> unit` | add or overwrite an arbitrary response header (`Access-Control-Allow-Origin`, `Cache-Control`, `Set-Cookie`, …) |

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

### Build

```sh
dune exec ./bin/mere.exe -- -w -o echo.wat examples/http_echo_server.mere
wat2wasm echo.wat -o echo.wasm
```

### Run

```sh
node scripts/run_http_server.js echo.wasm
# In another terminal:
curl http://localhost:8080/hello
# → Hello: GET /hello
```

`scripts/run_http_server.js` is the reference host — it merges the
`http` glue with the standard Wasm env imports (`puts`, math libc
stubs, etc.) and calls `instance.exports.main()`.

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

## MVP limitations

- **Node-only host**. The glue uses Node's `http` module; a browser
  fetch-based variant would need a different transport.
- **Streaming responses and binary payloads are unsupported**. The
  handler returns one UTF-8 string that becomes the whole response
  body. Chunked / SSE / websocket upgrade would need a different API
  shape (probably a Mere-side `strbuf`-like "response writer" that the
  glue drains asynchronously).
- **No custom request-header access**. Method + URL + body cross the
  boundary today. Custom headers and structured query parsing all
  happen host-side (or not at all).
- **Single handler per process**. Registering multiple servers on
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
The forthcoming lower-level `contrib/net` (raw sockets over a C
runtime) will slot in below this one when that path is available.
