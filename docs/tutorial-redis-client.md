# Tutorial: build a Redis client in Mere

This builds a working Redis client from the raw TCP externs — enough
to run `PING`, `SET`, `GET`, and `DEL` — so you learn the RESP wire
protocol and how Mere talks to the network. By the end you'll
understand exactly what `contrib/db/redis` does under the hood.

The complete program is
[`examples/tutorial_redis_client.mere`](https://github.com/merelang/mere/blob/main/examples/tutorial_redis_client.mere).

## Prerequisites

- A built `mere` compiler + `wat2wasm` + Node.js 22+
- A Redis server on port 15610:
  ```sh
  docker run -d --name mere-tut-redis -p 15610:6379 redis:7
  ```

The network externs (`tcp_*`) are provided by `run_wasm.js` and
`run_http_server.js` via a sync TCP worker — they aren't available on
Cloudflare Workers (no raw sockets there).

## RESP in one minute

Redis speaks **RESP** (REdis Serialization Protocol). It's line-based
and dead simple. The first byte of every reply says what type it is:

| First byte | Type          | Example on the wire     |
|-----------:|---------------|-------------------------|
| `+`        | simple string | `+OK\r\n`                |
| `-`        | error         | `-ERR unknown command\r\n` |
| `:`        | integer       | `:42\r\n`                |
| `$`        | bulk string   | `$5\r\nhello\r\n` (`$-1\r\n` = nil) |
| `*`        | array         | `*2\r\n...` (two more replies follow) |

Commands are sent as an **array of bulk strings**. `SET greeting hi`
goes out as:

```
*3\r\n $3\r\nSET\r\n $8\r\ngreeting\r\n $2\r\nhi\r\n
```

That's the whole protocol we need. `GET`/`SET`/`PING`/`DEL` never
return arrays, so we'll model four reply types and skip `*`.

## The externs

Mere reaches the network + raw memory through a handful of externs
the Node runner supplies:

```mere
extern fn tcp_connect: str -> int -> int;      // host, port -> fd
extern fn tcp_write:   int -> int -> int -> int; // fd, ptr, len -> n
extern fn tcp_read:    int -> int -> int -> int; // fd, buf, want -> n
extern fn tcp_close:   int -> unit;
extern fn str_ptr:     str -> int;             // byte address of a str
extern fn mem_alloc:   int -> int;             // scratch buffer -> ptr
extern fn mem_get_u8:  int -> int -> int;      // buf, offset -> byte
extern fn mem_to_str:  int -> int -> str;      // buf, len -> str
```

`str_ptr` + `tcp_write` send bytes; `mem_alloc` + `tcp_read` +
`mem_to_str` receive them.

## The reply type

Model the replies we handle as a variant:

```mere
type reply =
  | RSimple of str      // +OK
  | RError  of str      // -ERR ...
  | RInt    of int      // :42
  | RBulk   of str      // $5\r\nhello   ("" for nil, simplified)
  ;
```

## Step 1 — connect

```mere
let fd = tcp_connect "127.0.0.1" 15610 in
if fd < 1 then
  let _ = print "connect failed (is redis on :15610?)" in ()
else
  ... use fd ...
```

## Step 2 — send a command

Build the `*N\r\n$len\r\narg\r\n...` wire form and `tcp_write` it.
`build_args` and `arg_count` are top-level `let rec` (the Wasm
backend disallows `let rec` nested in a function body):

```mere
let rec build_args = fn (args: str list) -> fn (acc: str) ->
  match args with
  | Nil -> acc
  | Cons (a, rest) ->
    build_args rest (acc ++ "$" ++ show (str_len a) ++ "\r\n" ++ a ++ "\r\n")
  ;

let rec arg_count = fn (args: str list) ->
  match args with
  | Nil -> 0
  | Cons (_, rest) -> 1 + arg_count rest
  ;

let command = fn (fd: int) -> fn (args: str list) ->
  let n = arg_count args in
  let wire = "*" ++ show n ++ "\r\n" ++ build_args args "" in
  let _ = tcp_write fd (str_ptr wire) (str_len wire) in
  read_reply fd
  ;
```

## Step 3 — read a reply

Three readers, bottom-up. First, one byte:

```mere
let read_byte = fn (fd: int) ->
  let buf = mem_alloc 1 in
  let n = tcp_read fd buf 1 in
  if n < 1 then 0 - 1 else mem_get_u8 buf 0
  ;
```

A CRLF-terminated line (drops the `\r\n`) — used for status / error /
length lines:

```mere
let rec read_line = fn (fd: int) -> fn (acc: str) ->
  let b = read_byte fd in
  if b < 0 then acc
  else if b == 13 then          // '\r'
    let _ = read_byte fd in     // consume the '\n'
    acc
  else read_line fd (acc ++ chr b)
  ;
```

A bulk string reads an **exact byte count**, then the trailing CRLF.
This is why bulk uses a length prefix instead of line reading — bulk
payloads can contain `\r\n` or NUL bytes, so you can't scan for a
terminator:

```mere
let rec read_exact = fn (fd: int) -> fn (buf: int) -> fn (want: int) -> fn (got: int) ->
  if got >= want then got
  else
    let n = tcp_read fd (buf + got) (want - got) in
    if n <= 0 then got
    else read_exact fd buf want (got + n)
  ;

let read_bulk = fn (fd: int) -> fn (want: int) ->
  let buf = mem_alloc (want + 1) in
  let _ = read_exact fd buf want 0 in
  let _ = read_byte fd in       // '\r'
  let _ = read_byte fd in       // '\n'
  mem_to_str buf want
  ;
```

The parser dispatches on the first byte (`43` = `+`, `45` = `-`,
`58` = `:`, `36` = `$` in ASCII):

```mere
let read_reply = fn (fd: int) ->
  let ty = read_byte fd in
  if ty == 43 then RSimple (read_line fd "")
  else if ty == 45 then RError (read_line fd "")
  else if ty == 58 then RInt (int_of_str (read_line fd ""))
  else if ty == 36 then
    let len = int_of_str (read_line fd "") in
    if len < 0 then RBulk ""                        // nil ($-1)
    else read_bulk fd len |> (fn (s) -> RBulk s)
  else RError ("unexpected reply byte " ++ show ty)
  ;
```

## Step 4 — the demo

```mere
let r1 = command fd (Cons ("PING", Nil)) in
let r2 = command fd (Cons ("SET", Cons ("greeting", Cons ("hello mere", Nil)))) in
let r3 = command fd (Cons ("GET", Cons ("greeting", Nil))) in
let r4 = command fd (Cons ("GET", Cons ("missing-key", Nil))) in
let r5 = command fd (Cons ("DEL", Cons ("greeting", Nil))) in
```

## Run it

```sh
docker run -d --name mere-tut-redis -p 15610:6379 redis:7
./_build/default/bin/mere.exe -w examples/tutorial_redis_client.mere > /tmp/rc.wat
wat2wasm --enable-tail-call /tmp/rc.wat -o /tmp/rc.wasm
node scripts/run_wasm.js /tmp/rc.wasm
```

Output:

```
PING            -> +PONG
SET greeting    -> +OK
GET greeting    -> "hello mere"
GET missing-key -> "" (nil = empty)
DEL greeting    -> :1
```

Each line exercises one reply type: PING → simple string, SET → OK,
GET → bulk, missing key → nil bulk, DEL → integer.

## Where to go next

You've now implemented the core of a Redis client. The production
version in `contrib/db/` extends this same shape:

- **[`contrib/db/redis`](https://github.com/merelang/mere/blob/main/contrib/db/redis.mere)**
  — RESP2 **and** RESP3 (9 reply types incl. maps / sets / doubles /
  push), pipelining, binary-safe args (hex-boundary convention),
  AUTH, TLS with cert verification, and pub/sub.
- **[`contrib/db/redis_queue`](https://github.com/merelang/mere/blob/main/contrib/db/redis_queue.mere)**
  — `BRPOP` work queue on top of the client.
- **[`contrib/db/redis_stream`](https://github.com/merelang/mere/blob/main/contrib/db/redis_stream.mere)**
  — Streams + consumer groups (`XADD` / `XREADGROUP` / `XACK`).
- **[`contrib/db/redis_lock`](https://github.com/merelang/mere/blob/main/contrib/db/redis_lock.mere)**
  — distributed mutex (`SET NX PX` + compare-and-delete via `EVAL`).
- The [Database docs](db.md) list every Redis demo.

The `mem_alloc` / `tcp_read` / `mem_to_str` pattern here is the same
one the Postgres and MySQL drivers use — see
[`contrib/db/pg`](https://github.com/merelang/mere/blob/main/contrib/db/pg.mere).
