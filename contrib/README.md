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
- Mere core ships a **pkg manager** that can resolve external deps via `mere fetch`
- API has stopped breaking daily (= signature stable for 1+ month)
- At least one external consumer (Mere user code outside this repo) exists

## How to use (before pkg manager lands)

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

Copy-paste also works:

```sh
cp contrib/json/json.mere my_project/
```

Top-level libs originating from `examples/` (currently
`contrib/json/writer.mere` / `contrib/markdown/*`) still work, but to namespace
them, rewrite into `module Foo { ... }` form incrementally.

```sh
# Example: using JSON
cp contrib/json/json.mere my_project/
# `type json` and `parse_json` become available at the top of my_project/main.mere
```

When concatenated at the head of a file, top-level lets / types are injected
like a prelude. To avoid name collisions, contrib libs follow a **prefix
naming convention** (`json_parse / json_show / md_to_html / md_to_text`).

## Current contrib libs

| lib | path | function | module-wrapped |
|---|---|---|---|
| **json** | `contrib/json/` | JSON parse (`Json.parse_json`) + write (compact / pretty) | parser only |
| **markdown** | `contrib/markdown/` | Markdown subset → HTML (`MarkdownHtml.render`) / plain text / TOC | to_html.mere ✓, to_text / toc are top-level |
| **csv** | `contrib/csv/` | CSV parse (`Csv.parse_csv`, reduced RFC 4180) + writer (`CsvWriter.render` Person-bound) | ✓ both |
| **argparse** | `contrib/argparse/` | CLI argument parser (`Argparse.parse` flag/opt/positional) | ✓ module |
| **regex** | `contrib/regex/` | minimal regex (`Regex.parse_re` + `Regex.match_re`, `. ^ $ * + ?` + concat) | ✓ module |
| **test** | `contrib/test/` | unit test framework (`Test.assert_eq` + `Test.summary` + `Test.exit_status`) | ✓ module |
| **time** | `contrib/time/` | elapsed-seconds format helpers (`Time.format_elapsed` etc.). Wasm unsupported for now | ✓ module (3 backends) |
| **option** | `contrib/option/` | helpers complementing prelude (`Option.zip` / `filter` / `or_else` / `is_none` / `unwrap_or_fail`) | ✓ module |
| **path** | `contrib/path/` | POSIX path operations (`Path.join` / `basename` / `dirname` / `ext` / `drop_ext` / `has_ext`) | ✓ module |
| **toml** | `contrib/toml/` | TOML 1.0 reduced parser (`Toml.parse_toml` int / str / bool / array + nested section, flattened to dotted key) | ✓ module |
| **site** | `contrib/site/` | docs site SSG (markdown dir → HTML pages + index). interp + C only | CLI script |
| **dom** | `contrib/dom/` | minimal browser DOM bindings (`dom_get_by_id` / `dom_set_text` / `dom_on_click` / `dom_input_value`). Wasm + `dom.glue.js` host | extern fn (Phase 48 C2 MVP) |
| **fmt** | `contrib/fmt/` | Mere self-host of `Mere.Formatter` — `format_expr` + `format_program` (Phase 49 + Stage 50g). Imports AST defs from `contrib/parser/ast.mere`. | top-level |
| **parser** | `contrib/parser/` | Mere self-host of `Mere.Lexer` + `Mere.Parser` — `tokenize` + `parse_decls` (Phase 50). Plus shared `ast.mere` consumed by fmt + eval. | top-level |
| **eval** | `contrib/eval/` | (in progress) Mere self-host of `Mere.Eval` — tree-walking interpreter over `ast.mere`'s `expr`. Stage 51a: literals / var / binop / cmpop / logicop / neg / if (Phase 51 in progress). | top-level |
| **http** | `contrib/http/` | minimal HTTP server bindings for Node-hosted Mere (`http_serve` + `http_current_body` + `http_set_status` + `http_set_content_type` + `http_set_header`). Wasm + `http.glue.js` host. Server-side sibling of `contrib/dom`. | extern fn (Phase 54 Stage A) |
| **orm** | `contrib/orm/` | typed row decoding + JSON encoding combinators over `str option list` rows (`Orm.dec_int` / `dec_str` / `dec_bool` / `dec_str_opt` + `decode_rows`; `Orm.enc_int` / `enc_str` / `enc_bool` / `enc_str_opt` / `enc_obj` / `enc_arr`). DB-agnostic; the ML answer to reflection-based ORMs. From the mere-blog dogfood. | ✓ module |

Future candidates: see internal design notes §3.

## Design rationale

For why this is split from `examples/`, see internal design notes §3.
