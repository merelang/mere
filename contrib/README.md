# contrib/ — incubating libraries

This directory holds Mere code that is **one step closer to "library" than
`examples/`**. That is, **functionality intended to be embedded in other Mere
programs**, not "demos to observe behavior standalone".

## Position (3-stage lifecycle)

| stage | location | nature |
|---|---|---|
| 1. example | `examples/foo.mere` | demo to observe behavior via standalone run |
| **2. contrib (incubation)** | `contrib/foo/` | **library candidate. Lives in main repo so it can be refactored atomically with core changes** |
| 3. separate repo | `github.com/merelang/mere-foo` | independent versioning / issues / PRs |

Conditions for graduation stage 2 → 3:
- Mere core ships a **pkg manager** that can resolve external deps (`mere install`
  from a `mere.toml` now does this; see [docs/packages.md](../docs/packages.md))
- API has stopped breaking daily (= signature stable for 1+ month)
- At least one external consumer (Mere user code outside this repo) exists

## How to use

Mere already implements **`module M { ... }` + `import "path";`**. Since Phase 41
made qualified pattern match (`match v with | Json.JNull -> ...`) work across all
4 backend codegens, the recommended approach is to **module-wrap contrib libs
to namespace them** (`contrib/json/json.mere` is the reference).

```mere
import "contrib/json/json.mere";
let v = Json.parse_json "[1, 2]" in
match v with
| Json.JArr xs -> "array"
| _ -> "other"
```

Outside this repository, depend on a library with `mere install`: a
`mere.toml` entry such as
`json = { git = "https://github.com/merelang/mere", subdir = "contrib/json", rev = "<commit>" }`
vendors it under `.mere_modules/`. See
[docs/packages.md](../docs/packages.md) for how the import path then resolves.

Copy-paste also works:

```sh
cp contrib/json/json.mere my_project/
```

Not every library is module-wrapped yet (the `module` column below says
`top-level`). Those still work: when imported or concatenated at the head of
a file, their top-level lets / types are injected like a prelude. To avoid
name collisions, they follow a **prefix naming convention** (`pg_query`,
`kv_get`, `store_watch`, `inc_touch`, `schema_fields`, …). To namespace one,
rewrite it into `module Foo { ... }` form.

## Current contrib libs

Libraries with a `README.md` link to it; the others document themselves in
the header comment of their source file (`mere doc <file>` prints each
top-level name with that comment).

| lib | path | function | module |
|---|---|---|---|
| **[argparse](argparse/README.md)** | `contrib/argparse/` | CLI argument parser (`Argparse.parse` + `has_flag` / `get_opt` / `get_pos`; `--flag`, `--opt v`, `--opt=v`, `--`) | `Argparse` |
| **async** | `contrib/async/` | sequencing for callback-shaped work: `type Task = (str -> unit) -> unit` and `async_pure` / `async_then` / `async_seq` / `async_each` / `async_map` / `async_all` | top-level |
| **auth** | `contrib/auth/` | HS256 JWT (`Jwt.sign` / `Jwt.verify`) over host base64url and HMAC-SHA256 externs | `Jwt` |
| **[bignum](bignum/README.md)** | `contrib/bignum/` | arbitrary-precision naturals as base-1e9 limb lists (`Bignum.from_int` / `add` / `mul` / `cmp` / `to_str` / `fact` / `fib`) | `Bignum` |
| **[codegen](codegen/README.md)** | `contrib/codegen/` | Mere self-host of the Wasm (WAT) backend — `compile_source_to_wat` (type-checked; used by the CLI and the browser page) and `parse_and_emit` | top-level |
| **[csv](csv/README.md)** | `contrib/csv/` | CSV parse (`Csv.parse_csv`, reduced RFC 4180) + writer (`CsvWriter.render`, bound to a `Person` record) | `Csv`, `CsvWriter` |
| **db** | `contrib/db/` | pure-Mere PostgreSQL (`pg_*`), MySQL (`mysql_*`) and Redis (`redis_*`, plus pub/sub, queue, streams, lock, rate limit, HyperLogLog, Sentinel, Cluster) clients and connection pools over host TCP / crypto primitives; `live.mere` derives which tables a SQL read or write touches. See [docs/db.md](../docs/db.md) | top-level |
| **[dom](dom/README.md)** | `contrib/dom/` | browser DOM bindings for Wasm: 35 `extern fn`s (elements, events, timers, fetch / SSE, canvas, audio) + the `dom.glue.js` host | extern fn |
| **[encoding](encoding/README.md)** | `contrib/encoding/` | WHATWG Encoding decoders — `Encoding.decode_labelled` / `decode_utf8` / `decode_windows_1252` / `label_of` (all labels), `Jis.decode_shift_jis` / `decode_euc_jp` | `Encoding`, `Jis`, `JisIndex`, `Labels` |
| **[eval](eval/README.md)** | `contrib/eval/` | Mere self-host of `Mere.Eval` — tree-walking evaluator over `contrib/parser`'s AST (`parse_and_eval` / `run_program` / `value_to_str`) | top-level |
| **feed** | `contrib/feed/` | RSS 2.0 / Atom feed extractor (`Feed.parse_feed`) on top of `contrib/xml` | `Feed` |
| **[fmt](fmt/README.md)** | `contrib/fmt/` | Mere self-host of `Mere.Formatter` — `format_expr` + `format_program` over `contrib/parser/ast.mere` | top-level |
| **[font](font/README.md)** | `contrib/font/` | a TrueType file as widths and outlines — `Font.load` / `text_width` / `glyph_quads` / `quads_cover` / `text_raster`. Imports nothing. glyf outlines and cmap format 4 only; no `.ttc`, no `gvar` | `Font` |
| **[gen](gen/README.md)** | `contrib/gen/` | thread-backed lazy generators (`Gen.make` / `next` / `take` / `fold`) | `Gen` |
| **[graphql](graphql/README.md)** | `contrib/graphql/` | GraphQL lexer / parser / printer (`Gparse.document`, `Gprint.document`), executor with introspection (`Gexec.run` / `run_json`) and validator (`Gvalid.validate`), each checked against graphql-js | `Glex`, `Gparse`, `Gprint`, `Gexec`, `Gvalid`, `Gintro` |
| **[html](html/README.md)** | `contrib/html/` | HTML tokenizer per the standard's state machine (`Html.tokenize`) + `build.mere`, an `html` tree whose `render` / `page` escape on output | `Html`, `Entities` (+ top-level `build.mere`) |
| **[http](http/README.md)** | `contrib/http/` | HTTP server externs (`http_serve`, `http_current_body`, `http_set_status` / `_content_type` / `_header`, `http_get_header`) for the Node host and the C backend, plus router, query, sessions, CSRF, CORS, metrics, static files, SSE, WebSocket, a client, and Mere-written concurrent servers | extern fn + top-level |
| **[http2](http2/README.md)** | `contrib/http2/` | HTTP/2 frames (`H2`), HPACK (`Hpack`) and an h2c gRPC server (`H2Server.serve` / `serve_pool` / `unary`) | `H2`, `Hpack`, `HpackTable`, `H2Server` |
| **inc** | `contrib/inc/` | recompute only what changed: `inc_declare` (a node and what it reads) / `inc_touch` / `inc_order` (dirty nodes, dependencies first) / `inc_put` / `inc_peek`, plus `inc_recomputes`. Dependencies are **declared, not traced**. Consumers and negative controls are in `test/inc/`; the gate is `scripts/inc_check.sh` | top-level |
| **[json](json/README.md)** | `contrib/json/` | JSON parse (`Json.parse_json`) + write (`Json.to_json_str` / `to_pretty_str`) over one `Json.json` type | `Json` |
| **kv** | `contrib/kv/` | append-only in-memory key/value log saved with `read_file` / `write_file` (`kv_new` / `kv_load` / `kv_save` / `kv_set` / `kv_get` / `kv_delete` / `kv_compact`), plus `pack.mere` (`pack2..5` / `split2..5`, `\|`-separated tuples) | top-level |
| **log** | `contrib/log/` | JSON-lines structured logger (`log_info` / `log_warn` / … and `*_f` with key/value fields; `set_log_level`, `log_from_env`) | top-level |
| **[mlint](mlint/README.md)** | `contrib/mlint/` | a Mere linter in Mere on the `contrib/parser` AST, rules as `dyn Rule` (unused binding / param, shadowing). `mere contrib/mlint/mlint.mere [file]` | top-level |
| **[option](option/README.md)** | `contrib/option/` | helpers complementing prelude (`Option.zip` / `filter` / `or_else` / `is_none` / `unwrap_or_fail`) | `Option` |
| **[ordset](ordset/README.md)** | `contrib/ordset/` | persistent sorted set generic over user `Eq` / `Ord` traits (`Ordset.empty` / `insert` / `member` / `of_list` / `to_list` / `size`) | `Ordset` |
| **orm** | `contrib/orm/` | typed row decoding + JSON encoding combinators over `str option list` rows (`Orm.dec_int` / `dec_str` / `dec_bool` / `dec_str_opt` + `decode_rows`; `Orm.enc_int` / `enc_str` / `enc_bool` / `enc_str_opt` / `enc_obj` / `enc_arr`). DB-agnostic; from the mere-blog dogfood | `Orm` |
| **os** | `contrib/os/` | synchronous shell-out (`subprocess_run` / `subprocess_status` / `subprocess_stderr`, host externs) and `parallel_map` (N commands at once via shell backgrounding, results in index order) | extern fn + top-level |
| **[parser](parser/README.md)** | `contrib/parser/` | Mere self-host of `Mere.Lexer` + `Mere.Parser` — `tokenize` + `parse_decls` / `parse_program_ast`, plus the shared `ast.mere` and `free_names.mere` used by fmt, eval, typer, codegen and mlint | top-level |
| **[path](path/README.md)** | `contrib/path/` | POSIX path operations (`Path.join` / `basename` / `dirname` / `ext` / `drop_ext` / `has_ext`) | `Path` |
| **[prop](prop/README.md)** | `contrib/prop/` | deterministic, index-driven input generators for the parity gates (`Prop.int_at` / `small_at` / `str_at` / `list_at`) | `Prop` |
| **[proto](proto/README.md)** | `contrib/proto/` | Protocol Buffers: wire format (`Wire`), `.proto` parser (`Pparse`), FileDescriptorSet byte-identical to protoc's (`Pdesc.of_source`), Mere code generation (`Pgen.file_source`) | `Wire`, `Pparse`, `Pdesc`, `Pgen` |
| **[raster](raster/README.md)** | `contrib/raster/` | 2D rasterizer with no window: premultiplied RGBA `Canvas` (`fill_rect` / `blend` / `to_ppm`) and antialiased `Path.fill` / `stroke` / `quad_to` / `cubic_to` | `Canvas`, `Path` |
| **[regex](regex/README.md)** | `contrib/regex/` | minimal regex (`Regex.parse_re` + `Regex.match_re`, `. ^ $ * + ?` + concat), plus a separate prototype `engine.mere` with alternation | `Regex` |
| **schema** | `contrib/schema/` | a record seen by field name — `schema_fields` / `schema_text` / `schema_with`, over the name-keyed view the compiler already synthesises for `to_json`. Lets a form be generated from a record declaration instead of written out beside it | top-level |
| **[site](site/README.md)** | `contrib/site/` | docs site SSG (markdown dir → HTML pages, nav, TOC, search index, sitemap, playground); `build_full.sh` builds the full site. Imports the `mere-markdown` package (`mere install` first) | CLI script |
| **[softfloat](softfloat/README.md)** | `contrib/softfloat/` | IEEE 754 doubles held in integer limbs, for backends without float (`add` / `sub` / `mul` / `fdiv` / `fsqrt`, `of_int` / `to_int`, decimal conversion); the RV32I float operators are built from it | top-level |
| **[state](state/README.md)** | `contrib/state/` | mutable state that says what it is: `cell_new` / `cell_get` / `cell_set` for a slot nothing is derived from, and `store_new` / `store_watch` / `store_update` for state the screen is a function of | top-level |
| **[store](store/README.md)** | `contrib/store/` | append-only durable key/value log on positioned file I/O (`kvlog_set` / `kvlog_get` / `kvlog_all`) | top-level |
| **[stream](stream/README.md)** | `contrib/stream/` | read a file one line at a time in memory bounded by the longest line (`Stream.each_line`, `Stream.count_lines`) | `Stream` |
| **[test](test/README.md)** | `contrib/test/` | unit test framework (`Test.new_suite` / `assert_eq` / `assert_true` / `summary` / `exit_status`) | `Test` |
| **[time](time/README.md)** | `contrib/time/` | elapsed-seconds format helpers (`Time.format_elapsed` / `to_ms` / `to_us`) | `Time` |
| **[toml](toml/README.md)** | `contrib/toml/` | TOML 1.0 reduced parser (`Toml.parse_toml` int / str / bool / array + nested section, flattened to dotted key; `get` / `has`) | `Toml` |
| **[typer](typer/README.md)** | `contrib/typer/` | Mere self-host of `Mere.Typer` — Hindley-Milner inference (`unify` / `infer` / `infer_decls` / `parse_and_infer`); also behind the browser type-checker page | top-level |
| **[unicode](unicode/README.md)** | `contrib/unicode/` | tables generated from the Unicode data: grapheme clusters (`Grapheme`), line breaking (`LineBreak`), NFC / NFD (`Normalize`), terminal column width (`Width`) | `Grapheme`, `LineBreak`, `Normalize`, `Width` (+ table modules) |
| **[url](url/README.md)** | `contrib/url/` | WHATWG URL parser checked against node's `URL` (`Url.parse` / `resolve` / `href` / `origin`, `Percent.encode` / `decode`, `Ipv6.canonical`) | `Url`, `Percent`, `Ipv6`, `Path` |
| **webhook** | `contrib/webhook/` | GitHub-style webhook helpers: `X-Hub-Signature-256` check (`GhWebhook.verify_signature`) and a one-line event summary (`GhWebhook.summarize`) | `GhWebhook` |
| **[window](window/README.md)** | `contrib/window/` | SDL2 window, pixels and input events, C backend only (`Window.open_` / `show` / `poll` / `close`); draws a `contrib/raster` canvas | `Window` |
| **xml** | `contrib/xml/` | minimal XML parser (`Xml.parse_xml`, `xml_name` / `xml_attr` / `children_named` / `first_named` / `text_content`); no DTDs | `Xml` |

## Design rationale

The split from `examples/` is the lifecycle above: an example is a program
you run to watch it, a contrib library is code other programs import, and it
stays in this repository until it can graduate to its own.
