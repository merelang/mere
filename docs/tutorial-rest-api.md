# Tutorial: build a REST API in Mere

This walks through a small notes REST API — create, list, fetch, and
delete notes over HTTP — using the `contrib/http` stack. By the end
you'll have a running JSON API and understand how routing, request
bodies, and path parameters fit together in Mere.

The complete program is
[`examples/tutorial_notes_api.mere`](https://github.com/merelang/mere/blob/main/examples/tutorial_notes_api.mere);
this page builds it up piece by piece.

## Prerequisites

- A built `mere` compiler (`dune build`; see the [README](https://github.com/merelang/mere#build--run))
- `wat2wasm` (from [wabt](https://github.com/WebAssembly/wabt))
- Node.js 22+ (the HTTP server runs under `scripts/run_http_server.js`)

No database — storage is in-memory, so there's nothing to install.

## What we're building

| Method + path      | Does                          | Returns |
|--------------------|-------------------------------|---------|
| `POST /notes`      | create a note                 | `{"id":"..."}` (201) |
| `GET /notes`       | list all notes                | `[{"id","title"}, ...]` |
| `GET /notes/:id`   | fetch one note                | `{"id","title","body"}` (404 if gone) |
| `DELETE /notes/:id`| delete a note                 | `{"deleted":true}` (404 if gone) |

## Step 1 — a server that routes

Every `contrib/http` app is a `str -> str` function (raw request line
→ response body) handed to `http_serve`. The `router` turns a
declarative route table into that function:

```mere
extern fn http_serve: int -> (str -> str) -> unit;
extern fn http_set_status: int -> unit;
extern fn http_set_content_type: str -> unit;

import "../contrib/http/router.mere";

let hello = fn (req: str) ->
  let _ = http_set_content_type "text/plain" in
  "hello\n"
  ;

let not_found = fn (req: str) ->
  let _ = http_set_status 404 in
  "not found\n"
  ;

let routes = Cons (route "GET" "/" hello, Nil) in
let _ = http_serve 8080 (router routes not_found) in
0
```

`route method path handler` builds an exact-match entry; `router`
tries each in order and calls `not_found` on no match.

## Step 2 — in-memory storage + create

We store notes in two maps (title, body) keyed by a generated id,
plus a vector remembering insertion order for the list endpoint.
These live at the top level so every handler closes over them:

```mere
let titles = map_new () in
let bodies = map_new () in
let order  = vec_new () in
```

The create handler reads the JSON body, mints an id, and stores it.
`body_field` (from `contrib/http/json_body`) pulls a field out of the
request's JSON body; `gen_request_id ()` returns 16 random hex chars,
of which we take 8:

```mere
extern fn http_current_body: unit -> str;
extern fn gen_request_id: unit -> str;

import "../contrib/http/json_body.mere";
import "../contrib/http/escape.mere";   // for `jstr` (JSON-string quote)

let create = fn (req: str) ->
  let title = body_field "title" in
  let body  = body_field "body" in
  let id = substring (gen_request_id ()) 0 8 in
  let _ = map_set titles id title in
  let _ = map_set bodies id body in
  let _ = vec_push order id in
  let _ = http_set_status 201 in
  let _ = http_set_content_type "application/json" in
  "\{\"id\":" ++ jstr id ++ "}\n"
  ;
```

`jstr` wraps a string in double-quotes with proper JSON escaping —
use it for any value that goes into a JSON response, so titles with
quotes or newlines don't break the output.

> **Escaping the brace.** `"\{"` produces a literal `{`. In Mere a
> bare `{` inside a string starts `{expr}` interpolation, so JSON
> object literals need the leading brace escaped as `\{`.

## Step 3 — list all notes

Listing walks the `order` vector and builds a JSON array. The walk is
a **top-level** `let rec` — the Wasm backend doesn't allow `let rec`
nested inside a function body, so recursive helpers live at the top
level and take their state as parameters:

```mere
let rec _list_walk = fn (i: int) -> fn (n: int) -> fn (acc: str) ->
  if i >= n then acc
  else
    let id = vec_get order i in
    if not (map_has titles id) then _list_walk (i + 1) n acc
    else
      let sep = if str_eq acc "" then "" else "," in
      let item = sep ++ "\{\"id\":" ++ jstr id
              ++ ",\"title\":" ++ jstr (map_get titles id) ++ "}" in
      _list_walk (i + 1) n (acc ++ item)
  ;

let list = fn (req: str) ->
  let _ = http_set_content_type "application/json" in
  "[" ++ _list_walk 0 (vec_len order) "" ++ "]\n"
  ;
```

The `map_has titles id` guard skips ids that were deleted (see step 5)
— they stay in `order` but drop out of the maps, so the list simply
passes over them.

## Step 4 — fetch one note with a path parameter

`route_pattern` matches `:name` segments and hands the captured values
to the handler as a `str list` (in source order), followed by the raw
request:

```mere
let cap_id = fn (caps: str list) ->
  match caps with
  | Cons (id, _) -> id
  | Nil -> ""
  ;

let fetch = fn (caps: str list) -> fn (req: str) ->
  let id = cap_id caps in
  if not (map_has titles id) then
    let _ = http_set_status 404 in
    let _ = http_set_content_type "application/json" in
    "\{\"error\":\"not found\"}\n"
  else
    let _ = http_set_content_type "application/json" in
    "\{\"id\":" ++ jstr id ++
    ",\"title\":" ++ jstr (map_get titles id) ++
    ",\"body\":" ++ jstr (map_get bodies id) ++ "}\n"
  ;
```

## Step 5 — delete

`route_pattern` works with any method, so `DELETE /notes/:id` uses the
same capture mechanism. We just remove the id from both maps — the
list and fetch handlers already gate on `map_has`, so a deleted note
becomes invisible without rebuilding the order vector:

```mere
let remove = fn (caps: str list) -> fn (req: str) ->
  let id = cap_id caps in
  if not (map_has titles id) then
    let _ = http_set_status 404 in
    let _ = http_set_content_type "application/json" in
    "\{\"error\":\"not found\"}\n"
  else
    let _ = map_delete titles id in
    let _ = map_delete bodies id in
    let _ = http_set_content_type "application/json" in
    "\{\"deleted\":true}\n"
  ;
```

## Wiring the routes

```mere
let routes =
  Cons (route         "POST"   "/notes"       create,
  Cons (route         "GET"    "/notes"       list,
  Cons (route_pattern "GET"    "/notes/:id"   fetch,
  Cons (route_pattern "DELETE" "/notes/:id"   remove,
  Nil)))) in

let handle = router routes not_found in
let _ = http_serve 8080 handle in
0
```

Note that `POST /notes` and `GET /notes` (exact routes) coexist with
`GET /notes/:id` (a pattern route) — the router tries exact matches
and pattern matches together, in table order.

## Run it

```sh
./_build/default/bin/mere.exe -w examples/tutorial_notes_api.mere > /tmp/notes.wat
wat2wasm --enable-tail-call /tmp/notes.wat -o /tmp/notes.wasm
node scripts/run_http_server.js /tmp/notes.wasm
```

Then, in another shell:

```sh
# create
curl -X POST -d '{"title":"first","body":"hello world"}' localhost:8080/notes
#   → {"id":"60d53882"}

# list
curl localhost:8080/notes
#   → [{"id":"60d53882","title":"first"}]

# fetch
curl localhost:8080/notes/60d53882
#   → {"id":"60d53882","title":"first","body":"hello world"}

# delete
curl -X DELETE localhost:8080/notes/60d53882
#   → {"deleted":true}
```

Restarting the server clears all notes (storage is in-memory).

## Where to go next

- **Persistence** — swap the in-memory maps for a database. See
  [`contrib/db/pg_pool`](https://github.com/merelang/mere/blob/main/contrib/db/pg_pool.mere)
  and the [Database docs](db.md); the
  [`http_todo_pg`](https://github.com/merelang/mere/blob/main/examples/http_todo_pg.mere)
  example shows a Postgres-backed CRUD API.
- **Optimistic concurrency** — the production shape of this API adds
  `PUT` / `PATCH` plus `ETag` / `If-Match` so two clients can't
  clobber each other. See
  [`http_rest_notes`](https://github.com/merelang/mere/blob/main/examples/http_rest_notes.mere).
- **Auth** — gate the mutating routes with
  [`contrib/http/session`](https://github.com/merelang/mere/blob/main/contrib/http/session.mere)
  (cookie sessions) or
  [`contrib/http/basic_auth`](https://github.com/merelang/mere/blob/main/contrib/http/basic_auth.mere).
- **Middleware** — layer `with_metrics` (Prometheus), `with_cors`,
  `with_access_log` around the router. The
  [`http_admin_dash`](https://github.com/merelang/mere/blob/main/examples/http_admin_dash.mere)
  example composes six middleware modules.
- **The full catalog** — see [HTTP demos](http-demos.md) for the
  complete list of `examples/http_*.mere` servers.
