# contrib/store — durable key/value storage in Mere

`kvlog.mere` is an append-only key/value log built on the positioned file
I/O added in v0.1.153. A write appends one record and fsyncs; a read
replays the log and keeps the last value for each key.

| fn | signature | notes |
|---|---|---|
| `kvlog_set` | `str -> str -> str -> unit` | path, key, value — appends and fsyncs |
| `kvlog_get` | `str -> str -> str` | `""` when the key is absent |
| `kvlog_all` | `str -> (str * str) list` | latest value per key, in first-appearance order |

Record framing, repeated to the end of the file:

```
[u32 be keylen][key bytes][u32 be vallen][val bytes]
```

Keys and values are raw bytes, so UTF-8 survives: `str_len` counts bytes,
`substring` indexes them, and `ord` / `chr` round-trip one byte at a time.

## Why it is here

To be the *same* store on both sides of a local-first app. Compiled to C
it is the server's copy; compiled to Wasm it is the browser's; and the
files are byte-compatible, so either side can read what the other wrote.
`examples/tally` is that app — a counter board whose browser replica and
server replica both `import "contrib/store/kvlog.mere"`.

## Running it in a browser

The store needs synchronous positioned file I/O. In a browser that means
an OPFS access handle, whose `read(buf, {at})` / `write(buf, {at})` /
`flush()` / `getSize()` map one-to-one onto the builtins — but the API
exists only inside a Worker. So a browser deployment splits in two:

- the UI module on the main thread (`contrib/dom`),
- the store module in a Worker (`examples/tally/store.worker.js`),
- `worker_call` between them, which is asynchronous.

`scripts/run_dom_headless.mjs --worker <store.wasm>` runs that same split
under Node against the filesystem, with replies deferred to a later turn
so the asynchrony is faithful. The OPFS binding itself has no automated
coverage — this repo's CI has no browser.

One asymmetry worth knowing: acquiring an OPFS handle is asynchronous
even though operating on it is synchronous. `file_openrw` is a
synchronous Mere call and cannot await, so every file the module will
touch has to be opened before the module starts. A single-log store makes
that trivial; anything that opens files by name at runtime needs an
explicit mount step.

## Deliberate limits

- A read replays the whole log; a write reopens the file. Fine at the
  scale this is meant for, and it keeps durability easy to reason about.
- No compaction, so a hot key grows the file forever.
- No range scan or ordering — `kvlog_all` returns insertion order, not
  sorted order. A B+-tree (the mbtree dogfood) is the shape to reach for
  when that matters.
