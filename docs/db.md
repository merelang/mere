# Database support

Mere ships a pure-Mere PostgreSQL client. Everything from the wire
protocol to SCRAM-SHA-256 auth is implemented in Mere itself; the host
only exposes low-level TCP and crypto primitives. No `npm` packages
involved.

The rest of this page walks the stack top-down, then catalogs the 16
`examples/db_*.mere` demos.

## Layered architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  Mere application code                                             │
│  (e.g. examples/http_todo_pg.mere)                                 │
├────────────────────────────────────────────────────────────────────┤
│  contrib/db/pg.mere            contrib/db/pg_pool.mere             │
│  ─────────────────             ───────────────────────             │
│  Wire protocol (v3)            Keep-alive pool over pg.mere        │
│  Simple + extended query       Idle event pump                     │
│  Prepared statements           pg_pool_pump / release_notifs       │
│  Transactions + savepoints                                         │
│  COPY FROM/TO STDOUT                                               │
│  LISTEN / NOTIFY + async queue                                     │
│  URL parser (RFC 3986)                                             │
│  SCRAM-SHA-256                                                     │
├────────────────────────────────────────────────────────────────────┤
│  Crypto helpers                                                    │
│  sha256, hmac_sha256, pbkdf2_sha256, base64_encode/decode,         │
│  random_hex / random_b64, hex_xor                                  │
├────────────────────────────────────────────────────────────────────┤
│  Byte-buffer primitives                                            │
│  mem_alloc, mem_{set,get}_{u8,u16be,u32be}, mem_copy_str,          │
│  mem_to_str, str_ptr                                               │
├────────────────────────────────────────────────────────────────────┤
│  Sync TCP transport                                                │
│  tcp_connect / tcp_write / tcp_read / tcp_close / tcp_set_timeout  │
│  worker_thread + SharedArrayBuffer + Atomics.wait                  │
│  (scripts/tcp_worker.js)                                           │
└────────────────────────────────────────────────────────────────────┘
```

Everything below `contrib/db/pg.mere` lives in
[`scripts/pg_env.js`](https://github.com/merelang/mere/blob/main/scripts/pg_env.js)
and is shared between the CLI runner (`run_wasm.js`) and the HTTP
harness (`run_http_server.js`). Wasm's synchronous model composes
naturally with the request/response DB protocols; the worker-thread
transport bridges Node's async sockets so a Wasm-level
`tcp_read` blocks the way the caller expects.

Values crossing the extern boundary are hex-encoded whenever they'd
otherwise contain NUL bytes — Mere's `str` is C-string, so raw digests
and binary frames can't ride as strings. Frame construction uses
`mem_alloc` + `mem_set_u*be` so the resulting buffer is opaque to the
str layer.

## Quick start

```sh
# 1. Boot a Postgres. Trust-mode works for everything except db_scram,
#    which needs POSTGRES_HOST_AUTH_METHOD=scram-sha-256.
docker run -d --name mere-pg -p 15432:5432 \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres postgres:16

# 2. Build the driver + a demo.
./_build/default/bin/mere.exe -w examples/db_hello.mere > /tmp/db.wat
wat2wasm --enable-tail-call /tmp/db.wat -o /tmp/db.wasm

# 3. Run it.
node scripts/run_wasm.js /tmp/db.wasm
```

Expected output for `db_hello`:

```
connected
1 | hello
42 | world
```

## Public API reference

Import `contrib/db/pg.mere` for everything except the pool helpers,
which live in `contrib/db/pg_pool.mere`.

### Connect

| symbol | signature | notes |
|---|---|---|
| `pg_connect` | `host -> port -> user -> pw -> db -> fd` | trust / SCRAM auth |
| `pg_connect_url` | `str -> fd` | libpq URL, percent-decoded |
| `pg_parse_url` | `str -> (host, port, user, pw, db)` | IPv6 brackets ok |
| `pg_close` | `fd -> unit` | sends Terminate + closes tcp |

Auth methods: `trust` (any password accepted, pass `""`) and
`SCRAM-SHA-256`. Cleartext-password and MD5 aren't wired — the driver
prints a diagnostic and returns `-1` if the server asks for them.

### Query

| symbol | signature |
|---|---|
| `pg_query` | `fd -> sql -> (str option list) list` |
| `pg_query_meta` | `fd -> sql -> ((str, int) list, rows)` — columns + rows |
| `pg_query_params` | `fd -> sql -> str option list -> rows` |
| `pg_query_params_meta` | `fd -> sql -> params -> (cols, rows)` |

`_params` variants use the extended-query protocol
(Parse/Bind/Execute/Sync). Parameters are sent out of band — SQL
injection is impossible. Text format for both parameters and results;
callers add `::int` / `::uuid` etc. casts where PG can't infer.

### Prepared statements

Parse once, execute many:

| symbol | signature |
|---|---|
| `pg_prepare` | `fd -> name -> sql -> handle` |
| `pg_execute` | `fd -> handle -> params -> rows` |
| `pg_execute_meta` | `fd -> handle -> params -> (cols, rows)` |
| `pg_deallocate` | `fd -> handle -> unit` |

### Transactions

Callbacks return `'a option` — `Some` commits, `None` rolls back:

| symbol | signature |
|---|---|
| `pg_tx` | `fd -> (fd -> 'a option) -> 'a option` |
| `pg_tx_iso` | `fd -> opts -> body -> 'a option` |
| `pg_savepoint` | `fd -> name -> unit` |
| `pg_rollback_to` | `fd -> name -> unit` |
| `pg_release_savepoint` | `fd -> name -> unit` |
| `pg_savepoint_scope` | `fd -> name -> body -> 'a option` |

`pg_tx_iso`'s `opts` is spliced verbatim after `BEGIN` — pass constants
like `"ISOLATION LEVEL SERIALIZABLE READ ONLY"`, never HTTP input.

### Bulk transfer (COPY)

10-100× faster than a loop of `INSERT`s once batch sizes reach a few
hundred rows.

| symbol | signature |
|---|---|
| `pg_copy_from` | `fd -> table -> cols -> rows -> int` — row count or `-1` |
| `pg_copy_to` | `fd -> sql -> rows` — accepts subquery form |

Text format only — backslash / tab / newline / CR are escaped per PG's
`COPY` rules and `None` maps to `\N`.

### Pub/sub (LISTEN / NOTIFY)

| symbol | signature |
|---|---|
| `pg_listen` / `pg_unlisten` | `fd -> channel -> unit` |
| `pg_notify` | `fd -> channel -> payload -> unit` — interior `'` doubled |
| `pg_wait_notify` | `fd -> timeout_ms -> (int, str, str) option` |
| `pg_drain_notifications` | `fd -> (int, str, str) list` — pulls queued |
| `pg_poll_once` / `pg_poll` | `fd -> timeout_ms -> bool` / `unit` |

Every drain function inside `pg.mere` (query result, COPY, handshake)
captures async `NotificationResponse` messages into a module-level
FIFO queue instead of dropping them, so notifications that arrived
during a `pg_query` surface on the next `pg_drain_notifications`
without another wire read.

### Connection pool

Single-fd keep-alive — sufficient for the single-threaded runtime.

| symbol | signature |
|---|---|
| `pg_pool_open` | `url -> pool` — no connection yet |
| `pg_pool_acquire` | `pool -> fd` — lazy connect on first call |
| `pg_pool_release` | `pool -> fd -> unit` — no-op today, API symmetry |
| `pg_pool_release_notifs` | `pool -> fd -> notifs` — release + drain |
| `pg_pool_pump` | `pool -> timeout_ms -> notifs` — idle-tick polling |
| `pg_pool_close` | `pool -> unit` |

### Row access

`pg_query` returns `(str option list) list`. Helpers turn cells into
typed values:

| symbol | signature |
|---|---|
| `pg_val_or` | `str option -> str -> str` |
| `pg_col_int` / `pg_col_int_or` | ` -> int option` / ` -> int` |
| `pg_col_bool` / `pg_col_bool_or` | | |
| `pg_col_at` | `row -> i -> str option` |
| `pg_first_col` | `rows -> i -> str option` |

### Metadata

- `pg_type_name : int -> str` maps type OIDs to their canonical names
  (`int4`, `text`, `uuid`, `jsonb`, …). Unknown OIDs surface as
  `"oid=<n>"` so callers can pattern-match on the tag.

## Demo catalog

All demos live under [`examples/db_*.mere`](https://github.com/merelang/mere/tree/main/examples).
Build recipe (`db_hello` shown; substitute the file name):

```sh
./_build/default/bin/mere.exe -w examples/db_hello.mere > /tmp/db.wat
wat2wasm --enable-tail-call /tmp/db.wat -o /tmp/db.wasm
node scripts/run_wasm.js /tmp/db.wasm
```

Every demo is self-contained (its file header lists the exact docker
command needed) and cleans up on process exit.

| demo | shows |
|---|---|
| [db_hello](https://github.com/merelang/mere/blob/main/examples/db_hello.mere) | trust auth + simple query, minimal starter |
| [db_scram](https://github.com/merelang/mere/blob/main/examples/db_scram.mere) | SCRAM-SHA-256 handshake against a scram-only server |
| [db_params](https://github.com/merelang/mere/blob/main/examples/db_params.mere) | parameterized query — SQL injection payload lands as data, not SQL |
| [db_types](https://github.com/merelang/mere/blob/main/examples/db_types.mere) | RowDescription OIDs — `pg_type_name` on int4/text/bool/uuid/jsonb/… |
| [db_typed](https://github.com/merelang/mere/blob/main/examples/db_typed.mere) | `pg_col_int` / `pg_col_bool` / defaults / `pg_first_col` |
| [db_url](https://github.com/merelang/mere/blob/main/examples/db_url.mere) | libpq URL — IPv6 brackets, `?query`, `%40` percent decoding |
| [db_tx](https://github.com/merelang/mere/blob/main/examples/db_tx.mere) | `pg_tx` commit / rollback via body return value |
| [db_savepoint](https://github.com/merelang/mere/blob/main/examples/db_savepoint.mere) | isolation level + nested savepoint scope |
| [db_prepared](https://github.com/merelang/mere/blob/main/examples/db_prepared.mere) | named prepared statement, 5× execute, deallocate |
| [db_pool](https://github.com/merelang/mere/blob/main/examples/db_pool.mere) | single-fd keep-alive: same `fd` + backend pid across acquires |
| [db_pool_pump](https://github.com/merelang/mere/blob/main/examples/db_pool_pump.mere) | pool + LISTEN — pump / release-with-notifs / quiet tick |
| [db_copy](https://github.com/merelang/mere/blob/main/examples/db_copy.mere) | `pg_copy_from` — 1000 rows in one round trip, edge-case escapes |
| [db_copy_out](https://github.com/merelang/mere/blob/main/examples/db_copy_out.mere) | `pg_copy_to` — subquery form, escapes round-trip |
| [db_notify](https://github.com/merelang/mere/blob/main/examples/db_notify.mere) | LISTEN / NOTIFY with two connections + timeout path |
| [db_notify_async](https://github.com/merelang/mere/blob/main/examples/db_notify_async.mere) | notifications arriving inside another query's response stream |
| [http_todo_pg](https://github.com/merelang/mere/blob/main/examples/http_todo_pg.mere) | `contrib/http` + `pg_pool` — signup / login / todos backed by PG |

## Limitations and future work

- **Auth**: SCRAM-SHA-256 is the only strong method wired. Cleartext
  password and MD5 aren't; SCRAM-SHA-256-PLUS (channel binding) isn't
  either.
- **TLS**: no SSL negotiation yet. `?sslmode=require` in a URL is
  accepted by the parser but not enforced.
- **Binary column format**: everything is text. Encoding / decoding
  of PG binary format would let us skip a `pg_type_name`-based decode
  step for hot paths.
- **Column NULL asymmetry**: `pg_query` results distinguish NULL from
  `""` via `str option`; some helpers (`pg_col_int_or`) collapse them
  to a default for ergonomics.
- **Async event loop**: `NotificationResponse` handling is queue-based
  — the pool has a `pump` primitive but no background loop. A real
  event loop would need cooperation from the Node harness.
- **MySQL / SQLite**: not implemented. MySQL would fit on the same
  TCP + crypto substrate; SQLite would need either a fresh Mere
  implementation of the file format or a bundled Wasm build.
