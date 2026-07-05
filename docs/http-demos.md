# HTTP demos

A tour of the web-app patterns you can build with the
[`contrib/http`](https://github.com/merelang/mere/tree/main/contrib/http)
stack. Each demo is one `examples/http_*.mere` file plus a small
static HTML frontend.

All demos share the same build recipe:

```sh
./_build/default/bin/mere.exe -w examples/<name>.mere > /tmp/<name>.wat
wat2wasm --enable-tail-call /tmp/<name>.wat -o /tmp/<name>.wasm
node scripts/run_http_server.js /tmp/<name>.wasm
# open http://localhost:8080/ in a browser
```

The Node runner (`scripts/run_http_server.js`) provides the extern
imports (fs, crypto, http, curl). Every demo listens on port 8080,
so run one at a time. The outbound-only `http_client_auth` demo has
no server component; it also runs cleanly under the plain
`scripts/run_wasm.js` runner (they share the same `http_fetch` env).

## The router API

The routing table is a declarative `route_entry list` fed to
`router routes not_found`. Three entry constructors:

```mere
route         "GET"  "/"            home_h                 // exact
route_pattern "GET"  "/post/:slug"  post_h                 // :captures
route_prefix  "/admin"              admin_subtable         // mount subtree
```

- **`route`** — exact-path entry. Handler is `str -> str` (raw req → body).
- **`route_pattern`** — segments starting with `:` capture one URL
  segment each. Handler is `str list -> str -> str` (captures in
  source order, then req). Arity must match: `/post/:slug` matches
  `/post/hello` but not `/post/hello/extra`.
- **`route_prefix`** — nests a whole `route_entry list` under a URL
  prefix. Inner entries are declared relative to the mount point
  (`"/"` = mount root, `"/login"` = `<prefix>/login`). If the inner
  table has no match, dispatch falls through to the next outer entry.

Query strings are stripped before matching (`/search?q=hi` matches
`/search`), and the raw request line is still passed to handlers
that need to peek at headers or the query.

Full API + rationale in
[`contrib/http/router.mere`](https://github.com/merelang/mere/blob/main/contrib/http/router.mere).
The [`http_router_demo`](https://github.com/merelang/mere/blob/main/examples/http_router_demo.mere)
example exercises all three variants (including two-capture
`/user/:name/pet/:pet`).

## The catalog

| demo | pattern | line count |
|---|---|---:|
| [todo_app](#todo-app) | cookie session + KV persistence + rate-limited login | 328 |
| [feed_reader](#feed-reader) | outbound HTTP + RSS/Atom parsing + per-user cache | 350 |
| [webhook_receiver](#webhook-receiver) | HMAC-SHA256 signature verify + Slack forward | 250 |
| [ci_dashboard](#ci-dashboard) | workflow_run event ingest + status aggregation | 240 |
| [link_shortener](#link-shortener) | dynamic route via `not_found` (regex-validated code) | 260 |
| [mini_blog](#mini-blog) | markdown render + RSS 2.0 producer (round-trip with feed_reader) | 320 |
| [wiki](#wiki) | anonymous-edit wiki + append-only revision history | 380 |
| [chat](#chat) | Server-Sent Events broadcast + long-lived HTTP | 140 |
| [jwt_api](#jwt-api) | HS256 bearer auth (stateless — tokens survive restart) | 240 |
| [file_upload](#file-upload) | multipart/form-data parser + byte-identical download | 260 |
| [rest_notes](#rest-notes) | REST verbs (PUT/PATCH/DELETE) + ETag / If-Match concurrency | 300 |
| [csv_export](#csv-export) | chunked Transfer-Encoding streaming | 110 |
| [blog](https://github.com/merelang/mere/blob/main/examples/http_blog.mere) | markdown blog on Postgres — `route_prefix "/admin"` + `route_pattern "/post/:slug"` end-to-end | 560 |
| [client_auth](https://github.com/merelang/mere/blob/main/examples/http_client_auth.mere) | outbound HTTP — `http_fetch_h`, Bearer auth, per-call timeout, response header read | 80 |
| [gh_stars](https://github.com/merelang/mere/blob/main/examples/gh_stars.mere) | CLI — GitHub repo star count via `http_fetch_h` (optional `GITHUB_TOKEN` Bearer) + rate-limit header echo | 110 |
| [metrics_demo](https://github.com/merelang/mere/blob/main/examples/http_metrics_demo.mere) | Prometheus-style `/metrics` endpoint — counters + gauges + `with_metrics` middleware (auto-counts `http_requests_total{method,path}` + duration) via `contrib/http/metrics` | 70 |

## todo_app

Signup / login / logout with sha256-hashed passwords. Per-user
persistent todos stored in a log-structured KV. Cookie session,
brute-force throttle on the login endpoint (contrib/http/ratelimit).
The whole contrib/http stack layered in one file: `access_log →
security_headers → cors → static → router`.

- `POST /api/signup` — `{user, pass}`
- `POST /api/login` — sets `session=` cookie
- `GET /api/todos`, `POST /api/todos`, `POST /api/todos/toggle`, `POST /api/todos/delete`

Source: [examples/http_todo_app.mere](https://github.com/merelang/mere/blob/main/examples/http_todo_app.mere)

## feed_reader

The only demo that actively uses `contrib/http/client.mere`'s
outbound `http_fetch`. Users subscribe to feed URLs; a refresh
call fetches each with curl (spawnSync), parses via
`contrib/xml` + `contrib/feed`, and caches entries per user.

- `POST /api/feeds` `{url}`, `POST /api/feeds/refresh`
- `GET /api/entries` — cached entries across all subscriptions

Verified against real feeds: `news.ycombinator.com/rss`,
`blog.rust-lang.org/feed.xml`. 40+ entries survive server restart.

Source: [examples/http_feed_reader.mere](https://github.com/merelang/mere/blob/main/examples/http_feed_reader.mere)

## webhook_receiver

GitHub-style signed webhook ingress. `POST /webhooks/github` reads
the `X-Hub-Signature-256` header and verifies HMAC-SHA256 over the
raw body. Passing events go to an audit log and optionally forward
to a configured Slack URL.

- `POST /webhooks/github` — signed events
- `GET /audit` — recent deliveries
- `POST /config/forward` — set outbound target

Verified: unsigned / wrong-sig → 401, valid push/pull_request/issues
events → 200 + forwarded downstream.

Source: [examples/http_webhook_receiver.mere](https://github.com/merelang/mere/blob/main/examples/http_webhook_receiver.mere)

## ci_dashboard

Same ingress pattern as webhook_receiver but focused on GitHub
`workflow_run` events. Extracts nested JSON fields (via a small
scan-based finder) and maintains a per-`(repo, branch, workflow)`
status board.

- `POST /webhooks/github` — signed workflow_run
- `GET /api/jobs`, `GET /` — auto-refresh HTML dashboard

Source: [examples/http_ci_dashboard.mere](https://github.com/merelang/mere/blob/main/examples/http_ci_dashboard.mere)

## link_shortener

First demo with a dynamic route: `GET /<code>` is not in the fixed
route table; the `not_found` fallback validates the code as
`[A-Za-z0-9_-]+`, looks it up in KV, and returns a 302 redirect
while incrementing a per-code hit counter.

- `POST /api/shorten` — `{url, code?}`
- `GET /<code>` — 302
- `POST /api/links/delete`

Source: [examples/http_link_shortener.mere](https://github.com/merelang/mere/blob/main/examples/http_link_shortener.mere)

## mini_blog

Producer side of the XML round-trip. Admin login + POST creates
markdown posts; `/feed.xml` emits RSS 2.0 that `contrib/feed` (the
consumer side used by `feed_reader`) parses cleanly.

- Admin: `POST /api/login`, `POST /api/posts`
- Public: `GET /`, `GET /post/<slug>`, `GET /feed.xml`

Source: [examples/http_mini_blog.mere](https://github.com/merelang/mere/blob/main/examples/http_mini_blog.mere)

## wiki

Anonymous-edit wiki. Every save is a new `page/<slug>/v/<n>` key
in KV — nothing is ever overwritten, so the past state is always
retrievable and the "history" page is just a filtered key listing.

- `POST /api/pages` `{slug, title, body, author}`
- `GET /page/<slug>`, `GET /page/<slug>/v/<n>`, `GET /page/<slug>/history`

Source: [examples/http_wiki.mere](https://github.com/merelang/mere/blob/main/examples/http_wiki.mere)

## chat

Long-lived HTTP + SSE broadcast. `GET /sse/chat` is intercepted at
the Node glue layer (contrib/http/http.glue.js) and held open; a
POST to `/api/messages` fans out via `sse_broadcast` to every open
EventSource.

Two `curl -N /sse/chat` clients receive all events from a third
process in matching order — verified.

- `POST /api/messages`, `GET /sse/chat`, `GET /api/messages`

Source: [examples/http_chat.mere](https://github.com/merelang/mere/blob/main/examples/http_chat.mere)

## jwt_api

Stateless bearer auth via HS256 JWTs. No server-side session
table — the token payload itself carries the user claim. Signing
secret is persisted in KV so restarts don't invalidate outstanding
tokens.

- `POST /api/login` → `{ token }`
- `GET /api/me`, `GET /api/tasks`, `POST /api/tasks` — all with `Authorization: Bearer <jwt>`

Verified: tampered signature → 401, forged payload claiming
`sub=admin` → 401, restart preserves tokens.

Source: [examples/http_jwt_api.mere](https://github.com/merelang/mere/blob/main/examples/http_jwt_api.mere)

## file_upload

`multipart/form-data` parser written in pure Mere
(`contrib/http/multipart.mere`). Uploaded files land in KV and are
served back via `GET /files/<id>` with the right Content-Type +
Content-Disposition. Text files round-trip byte-identically.

- `POST /api/upload` — form-data with `file` field
- `GET /files/<id>` — inline download

Source: [examples/http_file_upload.mere](https://github.com/merelang/mere/blob/main/examples/http_file_upload.mere)

## rest_notes

Proper REST verbs (PUT / PATCH / DELETE) + ETag optimistic
concurrency. Each response carries `ETag: "v<n>"`; every mutation
requires `If-Match: <etag>` to match the server's current value or
returns 412 Precondition Failed. Two clients editing the same note
can't blindly clobber each other.

- `POST /api/notes`, `GET/PUT/PATCH/DELETE /api/notes/<id>`

Status codes matrix: 201/200/204/400/404/405/412/428.

Source: [examples/http_rest_notes.mere](https://github.com/merelang/mere/blob/main/examples/http_rest_notes.mere)

## csv_export

Pair to `chat`'s SSE: chat pushes small events to many subscribers,
this pushes one large payload to one client. Both hijack the
default "buffer then end" response cycle; the CSV handler calls
`http_stream_start` + repeated `http_stream_write` to emit rows
one at a time via chunked transfer encoding.

- `GET /api/logs.csv?rows=N` — streamed CSV

100 000 rows / 4.3 MB in ~100 ms on the demo machine, with no full-
body allocation on the Mere heap.

Source: [examples/http_csv_export.mere](https://github.com/merelang/mere/blob/main/examples/http_csv_export.mere)

## Shared contrib

Everything the demos import is under [`contrib/`](https://github.com/merelang/mere/tree/main/contrib):

- `contrib/http/` — 18 modules including `router` (exact / `:capture` / prefix), `client` (outbound curl-based fetch with request + response headers, per-call timeout), `metrics` (Prometheus-style counters + gauges + auto-counting middleware), `session` (in-memory cookie session store — random 16-hex ids, `HttpOnly; SameSite=Lax` defaults), `json_body`, `escape`, `cookie`, `security`, `access_log`, `cors`, `static`, `multipart`, `sse`, `stream`, and the Node glue
- `contrib/kv/` — log-structured KV + pipe-separated pack/unpack
- `contrib/xml/`, `contrib/feed/`, `contrib/markdown/`, `contrib/json/` — parsers / renderers
- `contrib/auth/jwt.mere` — HS256 sign / verify
- `contrib/webhook/github.mere` — GitHub signed webhook helpers
- `contrib/log/log.mere` — JSON lines logger

The refactoring sweep that extracted these has cut ~350 lines of
duplicated boilerplate out of the demos — a new HTTP handler
typically opens with 10 imports + 20 lines of business logic.
