# Changelog (mere)

Major implementation milestones recorded per-slice (newest first). See `git log` for detailed commit messages.

---

## 2026-07-04 — `contrib/http/router`: `route_prefix` mount points

Third arm of `route_entry`: `REPrefix of str * route_entry list`.
Declared via `route_prefix "/mount" inner_routes`, it nests a whole
route table at a common URL prefix. Inner entries are stated
relative to the mount point (`"/"` is the mount root, `"/login"` is
`"/mount/login"`, etc.), and if no inner entry matches the request
falls through to the next outer entry (rather than the prefix
"claiming" the URL).

Made the fall-through work cleanly by refactoring internal `_try` to
return `str option` — `Some body` on match, `None` on no-match —
with the top-level `router` invoking the fallback only if `_try`
returns `None`. No behavioural change for pure-exact / pure-pattern
route tables.

Dogfood in `examples/http_blog.mere`:
- All 9 `/admin/*` routes now live under `route_prefix "/admin"` —
  the admin subtree is declared as a self-contained table and
  reused as one entry.
- Edit / delete moved to `/admin/edit/:id` and `/admin/delete/:id`
  pattern routes — the hand-rolled query-string parse in
  `edit_form_h` (that reached into the raw request line because the
  router had already stripped the query) is gone. Cleaner URLs and
  one fewer papercut for the next demo author.

## 2026-07-04 — `contrib/http/router`: `:capture` path params

Extended `route_entry` from a bare tuple to a two-arm variant so the
router can dispatch on patterns without breaking the existing
exact-match API.

- `route` (backwards-compatible) — exact-path entry, unchanged
  signature. Existing 15 demos recompile with zero source changes.
- `route_pattern method path handler` — new. Path segments starting
  with `:` capture one URL segment each. Handler is
  `str list -> str -> str` (captures in source order, then req).
- Segment matching splits on `/`, ignores leading and trailing
  slashes, and requires arity to match exactly (no `*` glob).

Wired into `examples/http_blog.mere` — the previous
`not_found` + `str_starts_with "/post/"` workaround is gone; blog
now routes `/post/:slug` declaratively. `examples/http_router_demo`
gained two-capture `/user/:name/pet/:pet` for reference.

---

## 2026-07-02 — Phase 54.36 runtime codegen bootstrap unblocked

Root-caused the "runtime OOB" that had been the last unresolved self-host
gap since Phase 54.20 — turned out not to be a codegen bug but plain
memory exhaustion.

**Root cause**: OCaml-side wasm codegen defaulted to `(memory (export
"memory") 64)` — 64 pages = 4 MiB. Self-host `parse_and_emit "42"`
allocates ~30 MiB at peak (prelude tokens + parsed AST + emit strbuf).
The bump allocator has no `memory.grow`, so writes past 4 MiB trap.

Phase 54.20's 5/6-char boundary observation was a red herring: the
allocation crossed the 4 MiB line at a specific input-dependent point
that happened to correlate with name length in the isolation harness.
Phase 54.23's higher-order-list_map hypothesis was similarly incidental.

**Fix**:
- `lib/codegen_wasm.ml` — default memory 64 → 1024 pages (64 MiB)
- `contrib/codegen/codegen_wasm.mere` — same bump for the self-host
  codegen's own memory-line emission (16 → 1024)
- `test/test_basic.ml` — updated the "wasm: memory declared + exported"
  snapshot to expect 1024. `run_wasm` also now passes
  `node --stack-size=65500` because self-host workloads recurse
  thousands of frames before returning (default Node stack ~500 KB).

**Verified**: `examples/oneshot_codegen.mere` (imports the self-host
codegen and calls `parse_and_emit "42"`) now runs end-to-end under
Node, emits 80,744 bytes of WAT, exits cleanly. Previously trapped
with either "call stack size exceeded" or "memory access out of
bounds" depending on which limit hit first.

**Deferred**:
- `memory.grow` in the bump allocator. Bumping the default fixes the
  common case but doesn't help workloads > 64 MiB. Growth-on-demand
  needs instrumentation at every bump-alloc site — invasive rewrite
  in `lib/codegen_wasm.ml`.

**Follow-up (same day)**: `codegen_runtime_bootstrap` CI helper added
in `test/test_basic.ml`. Compiles `examples/oneshot_codegen.mere` via
the pre-built `_build/default/bin/mere.exe` (avoiding nested `dune
exec` inside `dune runtest`), runs the wasm under Node with a puts
hook that captures the auto-printed main result, and asserts the
expected value (80746 bytes for `parse_and_emit "42"`). This closes
the previously-deferred CI gap — regressions in the runtime
self-host path now fail CI immediately.

dune runtest: 1778 → **1779 passing**.

---

## 2026-07-02 — Phase 54.35 web backend Stage A (contrib/http)

First Node-hosted HTTP server bindings for Mere. Answers the question
"can I write a real web backend in Mere today?" — yes.

**Added**:

- `contrib/http/http.mere` — five extern fns:
  - `http_serve: int -> (str -> str) -> unit` — register handler, start server
  - `http_current_body: unit -> str` — read POST/PUT body
  - `http_set_status: int -> unit` — override response status
  - `http_set_content_type: str -> unit` — override `Content-Type`
  - `http_set_header: str -> str -> unit` — add arbitrary response header
- `contrib/http/http.glue.js` — Node glue with per-request slots for
  body / status / content-type / headers. Uses the same closure ABI
  as `contrib/dom` (Phase 48 C2 MVP): DataView-based `{env, fn_idx}`
  dispatch through the exported `__indirect_function_table`.
- `scripts/run_http_server.js` — reference host that merges standard
  env imports (`puts`, libc stubs, math) with the http glue.
- Four examples exercising the stack:
  - `examples/http_echo_server.mere` — minimal echo (~30 LoC)
  - `examples/http_echo_body.mere` — POST body via `http_current_body`
  - `examples/http_json_api.mere` ⭐ — six-endpoint JSON REST API with
    CORS via `http_set_header`, 404s via `http_set_status`
  - `examples/http_todo_api.mere` ⭐ — in-memory TODO CRUD with
    routing, top-level mutable `Map[str, str]` state, POST / GET /
    PUT / DELETE + 404s on missing ids
- README entries in `contrib/README.md` and `examples/README.md`
- Detailed `contrib/http/README.md` with API table, integration
  recipe, and MVP limitations

**Non-obvious gotcha caught in testing**: `http_current_body ()`
returns a pointer into a per-request scratch buffer that gets
overwritten at the start of the next request. Storing that pointer
directly in a `Map` for later reads returns garbage. Fix: copy the
bytes into the stable bump arena via `strbuf` before storing —

```mere
let buf = strbuf_new () in
let _ = strbuf_push buf (http_current_body ()) in
let text = strbuf_to_str buf in
map_set store id text
```

Documented in `contrib/http/README.md`.

**MVP limitations (documented)**: Node-only host, no streaming /
binary payloads, no custom request-header access, single scratch
buffer shared across servers.

**Position**: Stage 2 contrib (incubation), sibling of `contrib/dom`
on the server side. Graduation target is `mere-http` (separate repo)
once the package manager lands. A future lower-level `contrib/net`
(raw sockets over a C runtime) will slot in below this one.

---

## 2026-06-30 → 2026-07-01 — Phase 54 self-host bootstrap loop closes

Over 32 incremental slices (Phase 54.1 → 54.32) the Mere source of the
compiler pipeline was made to compile itself. **1622 → 1771 tests**. 17
contrib libraries are now self-host-compilable and go end-to-end through
`parse_and_emit_file → wat2wasm → node`.

**Milestones achieved**:

- **Compile-time self-compile loop closes**: `codegen_wasm.mere` (~2800
  lines) compiles itself through `parse_and_emit_file` to 1,560,495 bytes
  of valid WAT; `wat2wasm` accepts the output. CI-verified.
- **Runtime self-host of 5 major components**: `lexer`, `parser`,
  `evaluator`, `type inferencer`, and `formatter` all compile via the
  self-host pipeline AND run correctly under wasm. Ten bootstrap harness
  tests exercise real workloads:
  - `tokenize "let x = 1 in x"` → 7 tokens
  - `parse_decls (tokenize "let x = 1; let y = 2; let z = 3;")` → 3 decls
  - `parse_and_eval "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5"` → 120
  - `parse_and_infer "let x = 5 in x + 1"` → "int"
  - `format_program (parse "1 + 2 * 3")` → "1 + 2 * 3\n"
- **17 contribs self-host-compilable**: `ast` / `lexer` / `parser` /
  `typer` / `eval` / `fmt` / `json` / `path` / `option` / `regex` /
  `regex.engine` / `argparse` / `test` / `toml` / `markdown/to_html` /
  `markdown/to_text` / `markdown/toc`. `time.mere` still needs float
  codegen. 10 of the 17 have `bootstrap_wat_ok` CI checks.

**Key infrastructure added**:

- `parse_and_emit_file path` (Phase 54.10): recursive `import "..."` inline
  with cycle detection + column-0 marker scan.
- `selfhost_prelude` (Phase 54.9 + 54.11 + 54.27): auto-prepended Mere
  source with `list_map` / `list_rev` / `list_fold` / `list_len` /
  `list_append` / `list_mapi` / `list_filter` / `list_iter` / `list_any` /
  `list_all` / `str_join` / `str_split` / `str_trim` / `str_replace`, plus
  `type __list_t = Nil | Cons of int;` / option / result so tags register
  deterministically.
- Constructor-arity rewrite (Phase 54.13): parser post-pass that walks
  `TopType` decls, builds an arity map, and rewrites
  `EApp(EConstr name None, x)` → `EConstr(name, Some x)` when arity is 1 —
  fixes the `Some x` bare-app trap the atom-level parser can't disambiguate.
- Stdlib builtins in `codegen_wasm.mere`: `ord` / `chr` / `is_digit` /
  `is_alpha` / `is_space` / `str_len` / `char_at` / `str_starts_with` /
  `substring` / `str_index_of` / `str_repeat` / `int_of_str` / `str_unescape` /
  `str_eq` / `strbuf_new` / `strbuf_push` / `strbuf_to_str` / `strbuf_len` /
  `map_new` / `map_set` / `map_get` / `map_has` / `read_file` / `not` /
  `fail`; every one gets a WAT helper.
- Semantic fixes: `$char_at` returns a 1-byte str (matching OCaml
  `V_str`), `==`/`!=` on any `EStr` literal lower to `$__lang_streq`, and
  `str_eq` provides explicit content equality for two runtime strings.
- Parser extensions: `module M { }` / `extern fn` / `fn _` / `fn (a: t)` /
  cons-tail `[h, ...t]` / `'a` tyvar / char literal / `'X'` / tuple
  destructure shorthand / `Module.Ctor` in patterns and expressions /
  float literal skip (integer part only) / `region R { <expr> }`
  permissive.

**Outstanding**: runtime self-compile of the codegen itself
(`parse_and_emit` running inside the compiled wasm) traps in an isolated
8-line region — a wasm-level bug that shows up specifically with 6+
character identifier names. Documented reproduction; needs interactive
wasm memory inspection to close. Time.mere waits on proper float codegen.

---

## 2026-06-22 (cont. — Phase 38.G-1 OwnedVec auto scope-bound Drop)

After Phase 38.C finished, during the public-release prep session we consumed
**Level 1** of DEFERRED §1.3. **1515 → 1526 tests**. Implements N1 of the
N1/N2/N3 decomposition that was paper-validated in the design doc
(`39_nll_linear_design.md`).

- **Behavior**: for `let v = owned_vec_new () in body`, if static analysis
  can confirm that `body` does **not lexically escape** `v`, we auto-emit
  `free(v->data)` at scope end (same shape as Phase 15.13 `with`).
- **Static analysis** (new helpers in codegen_c.ml):
  - `no_value_leak v body`: checks that `Var v` does not appear in value
    position of Tuple / Constr payload / Record_lit / Record_update / Fun body.
  - `tail_does_not_return_v v body`: checks that the tail expression's type
    does not transitively contain OwnedVec.
  - Both pass → auto-Drop; either fails → fall back to existing registry +
    main-end sweep (safe-by-default, conservative).
- **Supported backends**: C + LLVM. Wasm uses bump-arena and has no
  per-allocation free, so Phase 38.G-1 is a no-op there (will enable if
  GC / linear-memory free arrives).
- **Escape patterns (no auto-Drop)**: tail of body returns `v` / `v`
  stashed in a tuple / closure captures `v` / tail type contains OwnedVec.
- **Auto-Drop patterns**: build → query → return scalar / each `if` arm is
  scalar / nested let chains whose tail is scalar / compatible with Phase
  38.C partial application.
- **Levels 2/3 (N2 NLL Light, N3 Full Linear, ~5–15 slices) remain
  deferred** — held back until dogfood actually hurts.
- **Relevant commit**: `76f00f8`

---

## 2026-06-22 (cont. — Phase 38.C multi-arg curried builtin first-class)

After Phase 37 finished, the public-release sprint **consumed DEFERRED §1.2
A2**. Multi-arg curried builtins now work in value / partial-app position on
all 3 backends. **1511 → 1515 tests**.

- **Design call**: the originally envisioned per-builtin × per-arity closure
  adapter template (extension of Phase 35.1 nullary) was **scrapped** —
  boilerplate would explode as builtin × arity × backend. Instead each
  codegen got an **AST-local synthesize** helper (`synthesize_curried_eta` /
  `_llvm` / `_wasm`); the Var handler detects a multi-arg curried builtin in
  value position and synthesizes a fully eta-expanded `fn __arg0 -> fn
  __arg1 -> ... -> builtin __arg0 ... __argN` Fun chain on the spot, then
  re-feeds it to `emit_expr`. The existing anonymous-Fun adapter machinery
  (Phase 5.7-b) builds the closure; the nested inner App hits each
  builtin's direct-call fast path.
- **Supported builtins (9)**: `owned_vec_push` / `owned_vec_get` /
  `vec_push` / `vec_get` / `vec_set` / `strbuf_push` / `map_get` /
  `map_has` / `map_set`.
- **Examples**:
  ```
  let push_v = owned_vec_push v in
  let _ = push_v 1 in
  let _ = push_v 2 in ...

  let set_in_m = map_set m in            // 1-arg partial of a 3-arg
  let _ = set_in_m "a" 1 in ...
  ```
- **Limitation**: fully unapplied (`let push = owned_vec_push`) becomes
  polymorphic after let-poly, so the use site must pin the type with `Annot`
  or a concrete argument (same constraint as Phase 35 nullary).
- **Slice layout**: `46b2704` Phase 38.C-1 spike (C / owned_vec_push) /
  `24ff513` 38.C-2 (C / remaining 2-arg) / `a6fb4bf` 38.C-3 (C / 3-arg) /
  `8265992` 38.C-4/5 (LLVM + Wasm port).

---

## 2026-06-22 (cont. — Phase 37 public-release prep)

A prep sprint to public-ize mere after Phase 36 syntactic sugar.
**LICENSE adopted + CI set up + B/A implementation polish complete**.
1488 → **1498 tests**.

- **LICENSE (MIT alone)**: `LICENSE` (MIT) + `CONTRIBUTING.md`, with a
  contributor heads-up that we may go MIT OR Apache-2.0 dual in the future.
  Matches the mainstream license of OCaml-family languages
  (Lua / Zig / Julia / Nim / F#). Strategy notes are in `internal design
  notes` Section F.
- **GitHub Actions CI**: ubuntu + macos × OCaml 5.1/5.4 running `dune build`
  + `dune runtest`. CI / License badges added to README.
- **Phase 37.B exhaustiveness Phase 2**: `is_total_pattern` recurses into
  tuple / record (`(a, b)` and `{ x = a, y = b }` count as total),
  type hints attached to wildcard warnings for int / str / float / tuple /
  record (`"no wildcard arm for int"` etc.). 1488 → 1494 tests.
- **Phase 37.A `while` at top-level (3 backends)**: extended C / LLVM / Wasm
  `lift_fn_skels` so `let _ = while cond do body;` works directly under
  `main`. When `Let (P_*, Let_rec (bs, lr_body), rest)` is seen, `bs` is
  lifted to a top-level fn skel and the value is replaced with `lr_body`.
  1494 → 1498 tests.
- **Phase 37.C multi-arg curried builtin first-class**: the remainder of
  DEFERRED §1.2 A2. Re-estimated implementation size and **deferred to
  Phase 38.C** (closure-form for 2-arg curried builtins requires
  outer/inner adapter generation in two stages, with boilerplate piling up
  across 10+ builtins like vec_push / map_set × 3 backends).
- **`.gitignore` / `.gitattributes`**: ignore editor / OS / codegen output;
  `*.mere linguist-language=OCaml` as interim highlighting until Linguist
  registration.
- **CLI ergonomics polish**: `--version` / `-v` flag, explicit error for
  unknown flags, help text updated to reflect 4-backend feature parity
  (dropped legacy "Phase N prep, int subset" wording), added pointer to
  docs / examples at the end of help.
- **opam packaging**: `(package mere)` in `dune-project` + `(public_name
  mere)` in `bin/dune`. `generate_opam_files true` auto-generates
  `mere.opam`. `opam install .` works.

---

## 2026-06-22 (cont. — Phase 36 syntactic sugar + dogfood examples)

After Phase 32 (FFI), ran straight through Phase 33 (dogfood example batch
+ did-you-mean expansion), Phase 34 (float on 3 backends + libm dispatch),
Phase 35 (DEFERRED §1.2 A1: nullary factory builtin first-class value), and
Phase 36 (13 syntactic sugars + 16 prelude entries + 47 examples + 8
DEFERRED fixes). **1486 → 1488 tests**, examples 61 → 118 (47 new), the
syntactic surface reached practical territory for an ML-family language.

- **Phase 36 sugars (13 kinds)**: range `a..b` / operator section `(+ 1)` /
  cons `1 :: xs` / reverse pipe `f <| x` / apply `f @@ x` / lambda
  shorthand `\x -> ...` / string interpolation `"x = {show n}"` (lexer
  re-tokenizes recursively, `\{` to escape, nested strings rejected) /
  `?` (Option early-return) / `?!` (Result early-return) / list
  comprehension multi-gen `[f x | x <- xs, p x]` / `if let pat = e then
  ... else ...` / `for x in xs do body` (→ `list_iter`) / `while cond do
  body` (→ `let rec __while_N = fn () -> if cond then body; __while_N ()
  in __while_N ()`).
- **Phase 36 prelude (16 entries)**: `range` / `list_filter` / `list_take` /
  `list_drop` / `list_find` / `list_append` / `list_concat` /
  `list_flat_map` / `list_zip` / `list_for_all` / `list_any` /
  `list_member` / `list_sum` / `list_product` / `list_max` / `list_min`
  (cumulative 34 entries). `sum` / `product` / `max` / `min` are defined
  with `let rec` (looks complex because the test helper
  `codegen_with_decls` skips `Top_let_rec`).
- **Phase 36 DEFERRED fixes (8)**: §1.13 narrowed value restriction (do
  not generalize types containing mutable containers) / §1.14 lifted
  closure capture goes through `load` / `global.get` for globals / §1.15
  C codegen O(2^N) slowdown on deep list literals (double `emit_expr arg`
  inside Constr → cache once) / §1.16 `strbuf_to_str` inside a region had
  dangling pointer on region escape (C/LLVM switched to
  `__lang_default_region` alloc) / §1.17 C codegen `type result` shadow
  blew up `List.combine` (remove from `polymorphic_variants` + dedupe
  variant_decls last-wins) / §1.18 Phase 30.2 top-level global init order
  (source-order inline init) / §1.19 nested lambda unbound on top-level fn
  reference (added `closure_wrapper_forward_decls` in C/LLVM/Wasm; Wasm
  populates `fn_closure_table_idx` before `emit_fn_def`) / §1.20 C codegen
  forward decl for user record inside polymorphic variant (include mono
  variant/record bodies in the unified topo sort).
- **Phase 36 examples (47)**: basic dogfood (histogram / traffic_light /
  event_counter / html_builder / fallible_lookup / config_loader /
  csv_writer / markdown_to_text / calendar_lite / matrix_2d / borrow_chain
  / cache_sim / simple_query / caesar_cipher / fraction / roman_numerals /
  password_strength / brackets_balance / morse_code / luhn_check /
  tic_tac_toe / palindrome / anagram / base_conv / rps_game / scoreboard /
  eight_queens / collatz / bin_tree_traversal / knapsack / factory_value)
  + sugar showcase (range_demo / sections / cons_pipe_demo / sugar_demo /
  question_demo / sugar_showcase / comprehension / statistics /
  if_let_demo / for_loop_demo / while_loop_demo) + 4 big ones (csv_summary
  / game_of_life / sudoku_check / calc 138 lines / maze_solver BFS).
- **Phase 35**: extended DEFERRED §1.2 A1 (first-class factory builtin
  eta-wrap) to all 3 backends. Added eta_adapters to C/LLVM/Wasm so that
  unapplied builtins like `let mk = map_new` work correctly as values.
- **Phase 34**: float MVP rolled out to 3 backends. Phase 34.1 = C,
  Phase 34.2 = LLVM (`fadd` / `fsub` / `fcmp` + `@llvm.fabs.f64` +
  `__lang_str_of_float`), Phase 34.3 = Wasm (i32 ptr to heap-alloc f64
  slot + host import for formatting), Phase 34.4/34.5 = libm dispatch
  (sqrt/sin/cos/tan/f_pow/atan2) on 3 backends + `math_demo` example.
- **Phase 33**: dogfood example batch + did-you-mean expansion. Phase
  33.0 expanded did-you-mean to multi-candidate top-3 listing (partially
  closes DEFERRED §5.1). Phases 33.1–33.7 added D3 option_pipeline / H1
  prime_sieve / G5 rate_limiter / C4 stack_calc / G6 markdown_toc / G4
  bank_account / H3 graph_bfs working with diff = 0 on 4 backends.

---

## 2026-06-22 (cont. — Phase 32 C1 FFI)

Right after Phase 31, ran Outlook §C1 (FFI = calling external C functions)
through 5 slices + 1 polish back-to-back. **1480 → 1486 tests**, the
`extern fn <name>: <ty>;` syntax lets libc functions be called directly
from all 4 backends. A step that takes Mere from "an experimental
language that runs by itself" to "a practical language that can talk to
the outside world".

- **Phase 32.6**: multi-arg curried extern (`extern fn setenv: str -> str
  -> int -> int;`) working on 3 backends. The `collect_extern` helper
  walks the App chain to gather all args. Added default JS impls for
  getenv / setenv / system to `scripts/run_wasm.js`. Added a 3-arg setenv
  example in `examples/ffi_demo.mere`; diff = 0 on 4 backends.
- **Phase 32.5**: added 4 + 2 tests for §32.1–32.4 + §32.6 (1484 → 1486),
  created `examples/ffi_demo.mere`.
- **Phase 32.4**: Wasm codegen emits `(import "env" <name> ...)` host
  import + `call $<name>`; default JS impls for getpid/getppid etc.
  injected into `scripts/run_wasm.js`.
- **Phase 32.3**: LLVM codegen emits `declare <ret> @<name>(<args>)` + call.
- **Phase 32.2**: C codegen emits `extern <ret> <name>(<args>);` decl +
  direct call. unit arg → `()`; unit return → `(call, 0)` for int-ification.
- **Phase 32.1**: lexer (T_extern) + AST (Top_extern) + parser + typer +
  pipeline + repl + bin + 9 mocks via `lookup_extern` in eval.ml (getpid /
  getppid / getenv / setenv / system / sleep / srand / rand / unix_time).
- **Phase 32.0**: `40_ffi_design.md` paper trial — fixed syntax / typing /
  ABI / per-backend strategy. MVP type range is int / bool / str / unit
  only; float / tuple / record / variant / callback deferred.

## 2026-06-22

Ran 11 slices of Phase 29-31 across the night. Starting from **16 examples
PERFECT on 4 backends**, finished dogfood (toy_sql 1165 LoC) → bug hunt →
all fixes → README polish in one day. 1469 → 1480 tests; DEFERRED §1.10 /
§1.11 / §1.12 fully resolved; mere reached a state presentable to
outsiders.

- **Phase 31.1**: README updated to reflect Phase 22-31 (1268 → 1480 tests;
  3 → 4 backend feature parity; toy_sql 1165 LoC; signature spread /
  Result helpers / inner-fn lifting / top-level globalization / Wasm
  runtime execution / str_compare on 3 backends).
- **Phase 31.0**: ported `str_compare` to 3 backends (C / LLVM / Wasm).
  Sign-normalized to match interp's OCaml `compare s t` (-1/0/1) exactly.
  C uses inline strcmp, LLVM uses strcmp + select, Wasm uses a dedicated
  runtime helper.
- **Phase 30.2c** ⭐: Wasm codegen declares non-fn top-level lets as
  `(global $name (mut i32))`, initializes them with `global.set $name` at
  main entry. Var emits `global.get $name`. Works uniformly since all
  values are i32.
- **Phase 30.2b**: LLVM codegen declares them as `@<name> = internal
  global <ll_type> zeroinitializer`, stores init at main entry, Var
  reference is `load`.
- **Phase 30.2a**: C codegen declares non-fn top-level lets as file-scope
  `static <type> <name>;`, initializes at main entry. The heuristic
  **only globalizes lets whose name shows up in skels' free_vars**,
  protecting existing tests. **DEFERRED §1.10 fully resolved on all 3
  backends**.
- **Phase 30.1** ⭐: when a captured name in a closure was shadowed by
  let, body emission now temporarily removes the shadowed name from
  `current_env_subst`. Root cause was not specific to P_tuple — it was
  **env_subst not respecting shadowing**. Applied to both Let P_var and
  Let P_tuple. **DEFERRED §1.11 fully resolved**.
- **Phase 30.0** ⭐: added `when not (Hashtbl.mem toplevel_fn_names ...)`
  guard to the hardcoded dispatch of builtins (`is_alpha` / `is_digit` /
  `is_space`). If a user-defined fn shadows them, builtin dispatch is
  skipped. Same pattern applied to C / LLVM / Wasm. **DEFERRED §1.12
  fully resolved**.
- **Phase 29.3** ⭐: implemented nested-loop JOIN in toy_sql + qualify_row
  + project_join + 7 JOIN tests. **toy_sql total 1165 LoC, diff = 0
  PERFECT on 4 backends, 59 tests** (tokenizer 22 + parser 13 + executor
  17 + JOIN 7). Final assessment of N1/N2/N3 dogfood: at 1165 LoC the
  demand never materialized; pain concentrated in codegen plumbing
  (DEFERRED §1.10–§1.12).
- **Phase 29.2**: toy_sql executor (Catalog Map[str, table_meta] +
  Storage OwnedVec[tagged_row] + WHERE filter + project + 17 tests).
  Map[K, V=variant] and OwnedVec[variant] codegen worked first try
  (symmetric to Phase 15.16).
- **Phase 29.1**: toy_sql SQL parser (AST + continuation flow + 13 tests).
  **Dogfood findings**: C codegen tuple destructure rebind bug
  (DEFERRED §1.11), Wasm memory expanded from 1 page (64KB) to 16 pages
  (1MB) for string-heavy apps.
- **Phase 29.0**: toy_sql foundation (Value variant + Token variant +
  hand-written tokenizer + 22 self-tests). **Dogfood findings**: C
  codegen record-field × nested-lambda capture bug (DEFERRED §1.10), C
  codegen shadowing user-defined fn with builtin (DEFERRED §1.12).

---

## 2026-06-21

After closing one deferred item in Phase 21, ran Phase 22 → 23 → **Phase
24-27 (29 slices straight)** to complete 4-backend feature parity, then
added 4 dogfood examples in Phase 28. **1268 → 1469 tests passing**,
DEFERRED §1.7 / §1.8 / §1.9 resolved, 16 examples match diff = 0 PERFECT
on all 4 backends.

- **Phase 28.1**: fix deep nested lambda capture bug in C codegen
  (DEFERRED §1.9). Added `pattern_vars_with_types` helper; Match
  emit_arms wraps arm body / guard in with_pat scope and prepends
  pattern bindings to current_var_types. Nested closures in arm bodies
  now pick up pattern-bound names in free_vars filter and write them
  into closure env. Same shape as LLVM Phase 25.3 (second N+1 → N
  backport).
- **Phase 28.0**: 4 new examples verified on 4 backends:
  - D2 `chained_parse.mere`: Result chain idiom (result_and_then /
    result_map / result_or_else)
  - C1 `state_machine.mere`: variant + match transitions
  - I1 `ini_parser.mere`: line parser + Map (Phase 27.1 insertion-order
    dogfood)
  - C5 `regex_lite.mere`: recursive AST + backtracking matcher

  **12 → 16 examples PERFECT-matching on 4 backends**. chained_parse
  surfaced C codegen `undeclared identifier 'rest'` (DEFERRED §1.9).
- **Phase 27.3** ⭐: Wasm ty_tag accepts StrBuf (releases blocker where
  Phase 15.9-implemented `mere_strbuf_*` runtime couldn't be used with
  StrBuf inside tuple/variant payload). **json_writer matches PERFECT on
  Wasm runtime → 12/12 PERFECT on Wasm → full 4-backend feature parity
  achieved**.
- **Phase 27.2** ⭐: Wasm runtime execution verification. Added
  `scripts/run_wasm.js` (Node.js host harness with puts / read_file /
  write_file imports). Wasm main tail emits `show_<main_ty> + puts`;
  `add_show_type main_ty` forces show emission for main_ty.
  **11/11 examples match PERFECT vs interp on Wasm runtime**.
- **Phase 27.1** ⭐: pinned interp Map iter order to insertion order.
  V_map changed to `(Hashtbl, value list ref)`; map_set appends new
  keys; map_iter iterates via the list. **All 3 backends now 12/12
  PERFECT** (C/LLVM 10 → 12; word_freq + mini_shell Map-order cosmetic
  diff gone).
- **Phase 27.0**: C codegen prints `"()"` for unit main_ty (backport of
  LLVM Phase 25.11). template_engine / json_writer / inventory /
  cap_handler no longer trail `()` on C; C PERFECT 6 → 10.
- **Phase 26 (7 slices)**: 11/12 examples EMIT + wat2wasm successful on
  Wasm codegen. Ported the cumulative Phase 22-25 features (variant
  boxed payload / stdlib builtins / try_or / inner let-rec lifting /
  multi-instantiation specialization / str_split / str_join / read_file
  / write_file / lift_fn_skels non-Fun walk / various polishing) to Wasm
  one slice at a time.
- **Phase 25 (13 slices)**: LLVM codegen runs 12/12 examples (PERFECT 10).
  In parallel with Phase 24.x C features, implemented boxed payload /
  stdlib / try_or / inner let-rec lifting / multi-instantiation
  specialization / show_str escape / fn dedup / nested P_constr /
  missing builtins / various polishing on LLVM side.
- **Phase 24 (5 slices)**: 12/12 examples working on C codegen
  (template_engine / json_writer / inventory / cap_handler / word_freq /
  mini_shell). Variant payload switched to `{ tag, payload_ptr }` boxed
  representation, unifying polymorphic variant containers across all 3
  backends.
- **Phase 23 (5 slices)**: json_parser matches interp 100% on C codegen
  (Phase 23.2 added result_map / result_and_then / result_or_else to
  prelude; Phase 23.3 per-instantiation specialization of polymorphic
  user let-rec; Phase 23.5 show_str escape — **DEFERRED §1.7 fully
  resolved**).
- **Phase 22 (5 slices)**: try_or + str ops (str_split / str_join /
  str_count / str_index_of) working on all backends.
- **Phase 21 (1 slice)**: partial resolution of DEFERRED §1.7 (first
  stage of polymorphic user let-rec monomorphization on C codegen).

---

## 2026-06-20

Started from Phase 15.16, then sprinted through Phase 16 / 17 / 18 in one
day. 1268 → 1304 tests, resolved 6 items: DEFERRED §1.4 / §1.5 / §1.6 /
§2.1 / §2.5 / §4.1. Reached a state with **4 backends matching exactly on
a non-trivial program (todo_app), full coverage of the 10-pair borrow
checker conflict matrix, and proper module scoping (M.Red qualified +
open A.B; nested paths)**.

- **Phase 18.2: `open A.B;` (open on nested module path)** — DEFERRED
  §4.1 fully closed. `module_bindings` registers under both short-name
  key and full-path key (`A.B`); parser's `T_open` refactored to a path
  parser. Existing `open M;` follows the same code path (1304 passing).
- **Phase 18.1: M-prefix scoping for ctors / records inside modules** —
  remainder of DEFERRED §4.1. After `module M { type T = Red | Blue; }`,
  qualified access `M.Red`, qualified record literal `M.Pt { ... }`, and
  qualified patterns `match v with | M.Red -> ...` all work. Same-named
  ctors across two modules can be disambiguated by qualified form. Loose
  coupling: new AST decls `Top_ctor_alias` / `Top_record_alias` + shared
  alias table (`Ast.ctor_aliases`) + typer.alias_ctor + eval normalizes
  to canonical name when constructing V_constr. Bare names still work
  for backward compat (1301 passing).
- **Phase 17.2: full 10-pair borrow conflict matrix + intra-tuple
  conflict** — resolves DEFERRED §2.5. Of the 4×4=10 conflict pairs,
  added tests for the 4 untested ones (SW×ER, SW×EW, ER×ER, ER×EW);
  changed `check_borrows` Tuple branch to sequential threading; added a
  "Conflict matrix and extension history" section to design doc 08
  (1295 passing).
- **Phase 17.1: track function-return borrow by let-bound name** —
  DEFERRED §2.1 fully resolved. For `let r = f x in let r2 = &mut R r`
  where `f` returns `&R T`, the let-bound name is used as a place and
  a synthetic borrow is added to active for conflict detection
  (1287 passing).
- **Phase 16 polish**: reflected friction points #1/#2/#3/#4 in tutorial
  / patterns (`{ t | f = v }` partial update, same-name rebinding, type
  annotation idiom for closure parameters). Phase 16 retrospective
  document created.
- **Phase 16.4: Wasm Region_block bump restore removed** — DEFERRED
  §1.6. Fixed bug where `let v = region R { vec_to_owned ... } in ...`
  allocates inside a region and escapes, but the region exit rewinds
  bump so subsequent allocations overwrite the escaped value. Aligned
  Wasm region semantics with arena-leak (1283 passing).
- **Phase 16.3: mk_logger / mk_metrics codegen on 3 backends** —
  DEFERRED §1.5. Brought interpreter-only Logger / Metrics cap builtins
  to C / LLVM / Wasm parity. Logger = `{ closure_str_unit info / warn /
  error }`; Metrics = `{ inc, record (curried str→int→unit) }`. Side
  change: `collect_arrow_types` (C/LLVM) recursively traverses known
  record field types → closure typedefs used only via Logger are also
  auto-emitted (1281 passing).
- **Phase 16.2: fix C codegen `let x = f x` same-name rebinding bug** —
  DEFERRED §1.4. `__auto_type x = ...x...` hits the C rule "a variable
  may not reference itself in its initializer" and triggers a clang
  error. `codegen_c.ml` Let uniformly expanded to 2-step form
  `({ __auto_type __let_tmp_<name> = <value>; __auto_type <name> =
  __let_tmp_<name>; <body>; })`; at rhs evaluation the new binding is
  not yet declared so the old binding is visible (1269 passing).
- **Phase 16.1: surface 6 friction points via practical example
  todo_app.mere** — 110-line TODO app combining OwnedVec[Task] + Logger
  + vec_map + region. Documented 2 by-design (#1/#2 immutable record
  update), 2 HM limits (#3/#4 field access inference), 2 real bugs (#5
  rebinding, #6 mk_logger codegen), 1 Wasm bug (§1.6) (1268 passing).
- **Phase 15 #16**: extended Map[R, K, V] K to payload-bearing variants
  across 3 backends (Mere's full concrete type set is now usable as a
  Map key).

---

## 2026-06-19

- **Phase 15 #16: extended Map[R, K, V] K to payload-bearing variants on 3
  backends** — extends Phase 15.15 nullary-variant K to also accept ctors
  carrying payloads. Now Mere's full concrete type set works as Map key.
  **(a) C codegen**: extended the variant branch of `key_eq_for` —
  `(a.tag == b.tag) && (a.tag == TAG_X ? eq_payload_X : a.tag == TAG_Y ?
  eq_payload_Y : ... : 0)` nested ternaries for per-tag dispatch; nullary
  ctors short-circuit to `1` (true). Payload recursively calls
  `key_eq_for`. C codegen accepts different payload types across ctors
  (leveraging variant's union representation). **(b) LLVM IR**:
  extended `emit_map_key_eq_helper_llvm` variant branch — extract tag
  with `extractvalue`, 0 if tags differ, otherwise extract payload and
  compare. **LLVM MVP restriction**: ctors must share the same payload
  type (MVP variant codegen requires a single payload type). Layered OR
  of "tag-in-nullary-set" checks for nullary ctors, combined with
  payload eq. **(c) Wasm**: extended `emit_map_key_eq_wasm` variant
  branch — load tag with `i32.load offset=0`, then a nested if/else
  chain `if (tag == TAG_X) then eq_payload_X else ...`. Last else is `1`
  (nullary or covered). Wasm also assumes uniform payload type under
  MVP, like LLVM. `is_key_supported` accepts payload variants on each
  of the 3 backends, recursively checking payload types. Added 5 tests
  (1268 passing) — C accepts mixed payload (A int / B str), LLVM/Wasm
  accept uniform payload (A int / B int / C nullary) + interpreter
  parity (1502, 603). **Side test-helper refactor**: changed
  `vec_codegen_c` / `_llvm` / `_wasm` test helpers to go through
  `typed_prog` and `Pipeline.process_decls` so Top_type etc. are
  registered first (programs with type decls used to typer-error in
  test helpers). Mere's Map key support now covers **all concrete
  types** (int / bool / str / tuple / record / nullary variant /
  payload variant). Remaining: first-class value usage; auto-Drop.

- **Phase 15 #15: extended Map[R, K, V] K to record / nullary variant on 3
  backends** — extends Phase 15.14 (tuple) so records and nullary
  variants also work as K. Enables meaningful maps with compound keys
  (e.g. `Pt { x, y } → value`, `Color = Red | Green | Blue → value`).
  Payload-bearing variants out of scope (per-tag union access is
  complex, candidate for separate slice). **(a) C codegen**: extended
  `key_eq_for` — records use `(a).field_name` for direct field access
  and recursive compare; nullary variants compare tags only with
  `(a).tag == (b).tag`. `is_key_supported` allows record / variant in
  both spots (Map type registration and `map_kv_tags_of`); judgment via
  `Typer.records` / `Exhaustive.type_variants`. **(b) LLVM IR**: inside
  `emit_map_key_eq_helper_llvm` `go` function, records get field via
  `extractvalue %RecName %r, i`; nullary variants get tag via
  `extractvalue %VarName %v, 0` + `icmp eq i32`. **(c) Wasm**: in
  `emit_map_key_eq_wasm` `build`, records get field via
  `i32.load offset=4*i` (memory-offset based); nullary variants get tag
  via `i32.load offset=0` + `i32.eq`. Error messages updated to
  "int / bool / str / tuple / record / nullary variant". Added 8 tests
  (1263 passing) — 3 backends × (variant key Color: 9, record key Pt:
  1000) accept + interpreter parity. Payload-bearing variants still
  rejected (DEFERRED §1.1 separately).

- **Phase 15 #14: extended Map[R, K, V] K to bool / tuple on 3
  backends** — extends Phase 15.10 (which had int / str only) to also
  accept bool / tuple (recursively). Enables compound keys (e.g.
  coordinates `(x, y) → ...`) with tuples. Key equality expands
  recursively per K structure. **(a) C codegen**: refactored
  `key_eq_expr` into recursive `key_eq_for k a b` — int/bool via `==`,
  str via `strcmp`, tuples access each field via `(a).f0, (a).f1, ...`
  and AND them. Tuples are C value types (struct), so direct field
  access works. **(b) LLVM IR**: emit one `@mere_map_key_eq_<K>` helper
  per K (called from `map_set / get / has`). Tuples are decomposed via
  `extractvalue` and recursively combined with `icmp eq + and i1`.
  `map_instances` is iterated for unique K and a helper is emitted per
  unique K in emit_program. **(c) Wasm**: all values are i32 but tuples
  access fields via memory offset. Added new `emit_map_runtime_wasm
  k_ty` function that generates 5 helpers per K (new/set/get/has/len)
  + `$mere_map_key_eq_<K>`. Phase 15.10 hardcoded `map_int_runtime_wasm`
  / `map_str_runtime_wasm` removed; `map_key_types : (string, Ast.ty)
  Hashtbl.t` registers K types → emit_program iterates. Tuple key
  equality in WAT uses block-scoped local.set + i32.load offset=4*i +
  recursive call_eq. Added 8 tests (1255 passing) — 3 backends × (bool,
  tuple key) accept + interpreter parity (bool: 302, tuple: 121).
  Remaining: extending Map K to record / variant (per-K eq logic is
  generic so extension is easy, but a separate slice is cleaner).

- **Phase 15 #13: scope-bound OwnedVec Drop via `with v = owned_vec_new
  () in body`** — complements Phase 15.8 process-wide registry
  (`__mere_owned_vec_free_all` at main end) by wiring OwnedVec into the
  `with` syntax. When written explicitly as `with v = owned_vec_new ()
  in body`, after body evaluation v->data is freed and the struct's
  data field is rewritten to NULL. The registry's `free_all` (at main
  end) tolerates `free(NULL)` (C standard no-op) while finally freeing
  the struct itself. Fits Mere's **"explicit > concise" philosophy** —
  the user opts into scope-Drop only when needed, safe without Rust-like
  move semantics or ownership analysis (creating an alias inside `with`
  and using it outside is still UB, but typer's Drop-type rule
  suppresses some of it). **(a) C codegen**: added branch to `Ast.With
  (name, value, body)` emission for `value.ty = OwnedVec`, inserting
  `free(((__mere_owned_vec_base*)name)->data);
  ((__mere_owned_vec_base*)name)->data = NULL;` after body. The
  `__mere_owned_vec_base` is the existing registry `{ void* data; int
  len; int cap; }` struct — generic free leveraging that all
  `mere_owned_vec_<T>` share the same leading layout. **(b) LLVM IR**:
  emit `getelementptr {ptr, i32, i32}, ptr v, i32 0, i32 0` to access
  struct field 0 (data ptr), then `load → @free → store null`. LLVM's
  opaque pointers + shared leading layout means it works without type
  tags. **(c) Wasm**: no malloc/free, just a linear-memory bump
  allocator, so **structurally a no-op** (process exit collects). No
  code change, but extended `resolve_vec_let_types` pre-pass to also
  walk With so typer type info flows correctly (shared across 3
  backends). Added 3 tests (1247 passing) — C/LLVM scope-end free
  emission + interpreter parity (30). Remaining: scope-bound Drop is
  **only on explicit `with`**; default `let` still relies on main-end
  registry sweep. Rust-style auto-Drop requires NLL + move semantics
  (DEFERRED §1.1).

- **Phase 15 #12: added `vec_to_list` + `len` on list to 3 backends** —
  added the remaining recursive-variant (Nil/Cons chain) construction
  + traversal in codegen. Parallel to Phase 15.7 `vec_to_owned`,
  `vec_to_list v` converts region Vec to `T list` (builds Cons chain
  bottom-up — start from Nil and prepend in reverse). `len` on list
  added; other types covered in Phase 15.11. **(a) C codegen**:
  vec_to_list inline-expanded in GCC stmt expression, calling
  `mere_vec_<T>_get(v, i)` in reverse and writing each into Cons
  payload `tuple_<T>_list_<T>` (`.f0 = elem, .f1 = acc`); new nodes
  allocated from default region. Cons/Nil tag values resolved at
  codegen time from `variant_tags`. Len on list inlined similarly
  (while loop with `__l->tag == cons_tag` condition,
  `__l->payload.Cons.f1` for next). **(b) LLVM IR**: per-T helpers
  `@mere_vec_to_list_<T>` and `@mere_list_<T>_len`, with phi for loop
  counter (i / acc) and list cursor. Assumes
  `%list_<T>_node = type { i32, %tuple_<T>_list_<T> }` exists and
  accesses payload via `getelementptr`. `vec_to_list_instances :
  (string, Ast.ty * Ast.ty) Hashtbl.t` tracks per-T, deduped in
  emit_program. **(c) Wasm**: shared `$mere_vec_to_list` and
  `$mere_list_len` helpers (Wasm values are all i32 and list structure
  is uniform). Tag values pulled from `variant_tags` at codegen time
  and baked into runtime; `vec_to_list_used` / `list_len_used` flags
  for lazy emit. Added 7 example tests (1244 passing) — 3 backends ×
  (vec_to_list / len-on-list) + interpreter parity. `v2l_src`
  program: `type 'a list = Nil | Cons of 'a * 'a list; ...
  vec_to_list v ...` computing `len l + head`; 13 on 3 backends +
  interp. Remaining: Map K extension (tuple / record / variant key);
  first-class value usage (`let f = vec_new in ...`); OwnedVec
  scope-bound Drop.

- **Phase 15 #11: 3 backends got `len` ad-hoc polymorphic builtin
  codegen** — `len : 'a -> int` had runtime dispatch in the
  interpreter; codegen now uses compile-time dispatch (statically
  routes to the corresponding `_len` helper based on arg.ty). **(a) C
  codegen**: in the `Ast.Var "len"` App handler, walk `arg.ty` for
  dispatch — `Vec[_, T]` → `mere_vec_<T>_len`, `OwnedVec[T]` →
  `mere_owned_vec_<T>_len`, `StrBuf` → `mere_strbuf_len`,
  `Map[_, K, V]` → `mere_map_<K>_<V>_len`, `str` →
  `((int)strlen(...))`, `TyTuple ts` → static arity constant
  (`({ (void)(arg); N; })` evaluates side effects). **(b) LLVM IR**:
  same pattern; emit `call i32 @mere_vec_<T>_len(ptr %a)` etc. via
  fresh_reg; str via `@strlen → trunc i64 to i32`; tuple evaluates
  side effects via emit_expr then returns as constant register via
  string_of_int. **(c) Wasm**: Vec / OwnedVec share `$mere_vec_len`
  (same struct layout in Wasm); StrBuf / Map use their helpers; str
  via `$__lang_strlen`; tuple via emit_expr + `drop` + `i32.const N`.
  On each backend, `len` is removed from Var rejection — only
  first-class value usage is rejected. `len` dispatch depends on
  arg's **static type**; if arg is polymorphic like `Vec[__heap, 'a]`
  the existing `resolve_vec_let_types` pre-pass concretizes it
  (collection-type support since Phase 15.2). Added 5 tests (1237
  passing) — 3 backends × (Vec / str / tuple) dispatch + interpreter
  parity (vec[3] + "hello"[5] + (1,2,3,4)[4] = 12). Remaining:
  `vec_to_list` (recursive variant codegen); Map K extension;
  first-class value usage.

- **Phase 15 #10: 3 backends got `Map[R, K, V]` codegen** — brought
  the region-aware mutable hashmap to 3 backend parity. Scope: **K =
  int / str + V = any concrete type**, linear scan (O(n) lookup), on
  cap-hit allocate new array in region (arena semantics). Brings the
  5 interpreter builtins from Phase 12.8 (`map_new` / `map_set` /
  `map_get` / `map_has` / `map_len`) to codegen. **(a) C codegen**:
  per-(K, V) `mere_map_<K>_<V>` struct `{ K* keys; V* values; int len;
  int cap; __lang_region* region; }` + 5 helpers. Key compare via `==`
  (int) or `strcmp(...) == 0` (str); set linear-scans for existing
  key and overwrites value, else appends to tail (on cap-hit, doubles
  array, memcpy to new region area). **(b) LLVM IR**: per-(K, V)
  `%mere_map_<K>_<V> = type { ptr, ptr, i32, i32, ptr }` + 5
  helpers. SSA phi for scan loop; key compare via `icmp eq i32` (int)
  or `@strcmp` (str). Grow path uses `getelementptr ... null, i32 1
  → ptrtoint` for sizeof(K) / sizeof(V), then @memcpy to migrate
  parallel arrays. get/has return `abort` / `ret i1 0` from
  `not_found` label. **(c) Wasm**: all values are i32, so **per-K
  only** (per-V not needed). 2 sets `$mere_map_int_*` and
  `$mere_map_str_*` (5 fns each); key compare via `i32.eq` or
  `$__lang_streq`. `map_int_used` / `map_str_used` flags for lazy
  emit — only one runtime is emitted if only one K is used. On each
  backend the App handler unwraps curried Apps; `map_new`'s region
  pulled from `e.ty` TyRef marker (same pattern as Vec / StrBuf).
  Rewrote existing "map: codegen rejection (C)" test to accept; added
  3 backends × (str/int) accept + interpreter parity, 8 tests total
  (1232 passing). Added `examples/map_codegen.mere`
  (str→int / int→str / Map inside region combined to return 640;
  interpreter + 3 backends all 640). Remaining: `vec_to_list` / `len`
  / first-class value usage.

- **Phase 15 #9: 3 backends got `StrBuf[R]` codegen** — brought the
  region-internal mutable string buffer to 3-backend parity. StrBuf
  is a single non-polymorphic type (no element-type parameter), so
  per-T monomorphization is not needed; a single runtime helper set
  (`new` / `push` / `to_str` / `len`) suffices. **(a) C codegen**:
  `mere_strbuf` struct `{ char* data; int len; int cap;
  __lang_region* region; }` + 4 helpers; push's realloc within same
  region (arena semantics); to_str copies null-terminated to region.
  `strbuf_used : bool ref` flag for lazy emit (zero overhead in
  programs that don't use it); added forward typedef. **(b) LLVM
  IR**: `%mere_strbuf = type { ptr, i32, i32, ptr }` + 4 helpers;
  push calls `@__lang_region_alloc` + `@memcpy`; push's resize loop
  is br-back form (double cap until enough capacity); to_str
  allocates `len+1` bytes + memcpy + null terminator. **(c) Wasm**:
  `$mere_strbuf_new / push / to_str / len` added as an independent
  runtime block (no closure dispatch, separated from
  vec_higher_order). `$__lang_bump` shared; strings copied byte by
  byte with i8 store/load; resize-time memcpy also hand-written
  loop. On each backend, App handler unwraps curried form `App ({
  Var "strbuf_push" }, sb)`; `strbuf_new`'s region pulled from
  `e.ty` TyRef marker (same pattern as Vec). Rewrote "strbuf:
  codegen rejection (C)" to accept; added 3 backends × accept +
  interpreter parity, 4 tests total (1225 passing). Added
  `examples/strbuf_codegen.mere` (interpreter + 3 backends return
  48: len of `"hello, world!"` + len of string built in another
  region + sb1 len). Remaining: `Map[R, K, V]` / `vec_to_list` /
  `len` / first-class value usage.

- **Phase 15 #8: main-end batch free for OwnedVec (naive Drop)** —
  replaces the "leave it to process exit" approach of Phase 15.7 with
  explicit "batch free at end of main" for heap-allocated OwnedVec.
  Clean under valgrind / leak sanitizer. **Design**: all
  `mere_owned_vec_<T>` structs share the leading layout `{ T* data;
  int len; int cap; }`, so generic free works by casting the first
  field as `void* data` (`free(v->data); free(v);`). A process-wide
  registry (`void** items; int count; int cap;`) is a file-scope
  global; each `_new` helper registers the struct ptr, then `main`
  end's `__mere_owned_vec_free_all` iterates and frees all. **(a) C
  codegen**: added `owned_vec_registry_runtime` block
  (`__mere_owned_vec_register` / `__mere_owned_vec_free_all` + 3
  file-scope globals); `emit_owned_vec_runtime_for` calls
  `__mere_owned_vec_register(v)` at end of `_new`; `main` end calls
  `__mere_owned_vec_free_all()` (only when ≥1 OwnedVec is present).
  **(b) LLVM IR**: emit `owned_vec_registry_runtime_llvm`
  equivalently; registry expressed via global ptr / i32; `@realloc`
  to grow; free_all iterates via phi loop. Each
  `@mere_owned_vec_<T>_new` end calls `@__mere_owned_vec_register`;
  `@main` end calls `@__mere_owned_vec_free_all`. **(c) Wasm**: no
  malloc, allocation via `$__lang_bump` (linear memory); process
  exit hands the entire WebAssembly instance back to OS, so
  **explicit free is unnecessary / impossible** — registry /
  free_all not emitted (preserves current behavior). **Remaining
  limit**: process-wide, not scope-bound, so memory grows
  monotonically for long-running programs that create many
  OwnedVecs. Real scope-Drop with NLL / move semantics is future
  work. Added 4 tests (1222 passing) — C / LLVM assertContains for
  registry + free_all calls; Wasm negative test confirms no registry
  emitted.

- **Phase 15 #7: 3 backends got `OwnedVec[T]` + `vec_to_owned` /
  `owned_vec_to_vec`** — brought interpreter-only heap-allocated
  OwnedVec to 3-backend parity, including round-trip (deep copy)
  with region Vec. Drop processing omitted in this minimum scope
  (process exit collects). **(a) C codegen**: generates per-T
  `mere_owned_vec_<tag>` struct + 4 helpers (new/push/get/len) via
  `emit_owned_vec_runtime_for`; allocates with `malloc / realloc`.
  vec_to_owned / owned_vec_to_vec inlined in GCC stmt expression;
  the latter extracts the target region from e.ty TyRef marker
  (active region). `c_type_of` walks `OwnedVec[T]` →
  `mere_owned_vec_<tag>*` in parallel with Vec; forward typedefs
  added. **(b) LLVM IR**: per-T `%mere_owned_vec_<tag> = type { ptr,
  i32, i32 }` + 4 helpers; `getelementptr ... null, i32 1 →
  ptrtoint` for sizeof(T); push's realloc uses declared `@realloc(ptr,
  i64)`. Conversion helpers per-T `@mere_vec_to_owned_<tag>` /
  `@mere_owned_vec_to_vec_<tag>` implemented with SSA phi loops.
  **(c) Wasm**: values are all i32 and `$__lang_bump` is shared,
  so **OwnedVec runtime is physically the same as Vec** —
  owned_vec_new / push / get / len thin-alias-routed to
  `$mere_vec_*`; conversions use newly added `$mere_vec_clone`
  helper for deep copy (allocate new vec, loop element-push). Wasm
  owned_vec only retains drop_types' region-placement rejection;
  runtime representation distinction not needed. Extended
  `resolve_vec_let_types` pre-pass to also handle `Ast.TyCon
  ("OwnedVec", _)` on C / LLVM. Added
  `examples/owned_vec_codegen.mere` — vec → owned → vec round trip
  + fold returning 67 (interpreter + 3 backends all 67). Added 12
  tests (1218 passing) — 3 backends × (owned_vec / vec_to_owned /
  owned_vec_to_vec) codegen-symbol emit + 3 interpreter parity.
  Remaining: real Drop (per-instance free); `vec_to_list` (recursive
  variant construction); `StrBuf` / `Map` / `len` / first-class
  value usage.

- **Phase 15 #6: 3 backends got `vec_map` / `vec_filter` — all 5 main
  Vec higher-order APIs are present** — follows Phase 15.5 (vec_set
  / iter / fold) with the two region-preserving ones. Both APIs
  build a new Vec in the same region as the input (vec_map converts
  element type T → U; vec_filter keeps only elements where predicate
  is true). **(a) C codegen**: GCC/Clang stmt expression inlining;
  pull the original Vec's region from `__vc->region` to create new
  Vec via `mere_vec_<U>_new(__vc->region)`; expand closure dispatch
  in-line into a loop. vec_filter uses `__auto_type __x =
  mere_vec_<T>_get(...)` (compiler infers C type) and conditionally
  pushes via `mere_vec_<T>_push` based on predicate's if branch.
  **(b) LLVM IR**: vec_map per-(T, U) helper
  (`@mere_vec_<T>_map_<U>`); vec_filter per-T helper
  (`@mere_vec_<T>_filter`). Both pull the input Vec's region field
  (offset 12 = idx 3) via `getelementptr + load` and call
  corresponding `@mere_vec_<U>_new` / `@mere_vec_<T>_new` to make
  new Vec. phi manages loop counter; vec_filter conditional-pushes
  via `br i1` on predicate's i1. `vec_map_instances` /
  `vec_filter_instances` tables dedupe. **(c) Wasm**: all values
  are i32, so `$mere_vec_map` / `$mere_vec_filter` added to
  `vec_higher_order_runtime`. Both call `$mere_vec_new` (no region
  parameter in Wasm); apply closure to elements via
  `call_indirect`; push to new Vec via `call $mere_vec_push`. Added
  `examples/vec_map_filter_codegen.mere` (interpreter + 3 backends
  return 226). Added 9 tests (1206 passing) — 3 backends ×
  (vec_map / vec_filter) codegen-symbol emit + LLVM's per-(T, U)
  per-T branch confirmation + interpreter parity. **Now all 5 main
  Vec higher-order APIs (set / iter / fold / map / filter) work on
  3 backends**, with almost no gap to the interpreter. Remaining:
  `vec_to_list` / `vec_to_owned` / `OwnedVec` / `StrBuf` / `Map` /
  first-class value usage.

- **Phase 15 #5: 3 backends got Vec higher-order APIs (`vec_set` /
  `vec_iter` / `vec_fold`)** — Vec[R, T] working on 3 backends since
  Phase 15.2 / 15.3 / 15.4; this slice brings interpreter-only main
  higher-order APIs to parity. **(a) C codegen**: vec_set is a per-T
  runtime helper (`mere_vec_<T>_set`); vec_iter / vec_fold are
  inlined at call site (GCC/Clang stmt expression `({ ... })` writes
  local + for loop + closure dispatch directly). **Side bug fix:
  anonymous Fun in main_body wasn't draining closure adapter** —
  added `drain ()` after `let main_body = emit_expr body_expr in` in
  emit_program to re-collect `pending_closures`. **(b) LLVM IR**:
  vec_set is per-T helper; vec_iter is per-T helper
  (`@mere_vec_<T>_iter`); vec_fold is per-(T, U) helper
  (`@mere_vec_<T>_fold_<U>`). Hand-written SSA with basic blocks
  managing loop state (i, acc) via phi. **(c) Wasm**: all values are
  i32, so all 3 helpers shared single runtime (`$mere_vec_set /
  $mere_vec_iter / $mere_vec_fold`). `vec_iter / vec_fold` helpers
  reference `(type $cl)` + `call_indirect`, so even programs whose
  closure values aren't in the table need `(table 0 funcref)`
  empty-declared; isolated via `vec_higher_order_used : bool ref`
  flag + separate runtime block. On each backend, App handler unwraps
  curried Apps (vec_set / vec_fold are 3-arg = 2-stage unwrap;
  vec_iter is 2-arg = 1-stage). Added
  `examples/vec_higher_order_codegen.mere` (interpreter + 3 backends
  return 1234 demo). Added 12 tests (1197 passing) — 3 backends ×
  (vec_set / vec_iter / vec_fold) codegen + interpreter parity.
  Remaining: `vec_map` (region-preserving new Vec creation) /
  `vec_filter` (dynamic size calc) / `vec_to_list` / `vec_to_owned`
  / `OwnedVec` / `StrBuf` / `Map` / first-class value usage.

- **Phase 15 #4: Wasm codegen supports `Vec[R, T]` — full 3-backend
  feature parity** — followed Phase 15.2 (C) / 15.3 (LLVM) and ported
  Vec to Wasm. In Wasm Mere values are all 4-byte i32 (scalar direct
  for primitives; structured types are linear-memory offsets), so per-T
  monomorphization (as in C / LLVM) is not needed. Design call: single
  `$mere_vec_new / $mere_vec_push / $mere_vec_get / $mere_vec_len`
  runtime handles all element types. lib/codegen_wasm.ml: (1) added
  `vec_used : bool ref`, emit_expr sets true when going through
  vec_*; (2) 4 fns + struct layout `{data:i32, len:i32, cap:i32,
  _pad:i32}` (16 bytes) written into `vec_runtime` literal in WAT;
  push's realloc allocates from single `__lang_bump` = arena
  semantics; (3) `ty_tag` catch-all relaxed to allow TyRef _ R TyUnit
  (region marker); explicit Vec rejection removed; (4) Var handler's
  vec_* rejection retained only for first-class value usage; (5)
  4 special-cases added to emit_expr — `App (App (Var "vec_push", v),
  x)` unwrapped to runtime call; `vec_new`'s region argument ignored
  (Wasm bump is global); (6) introduced `resolve_vec_let_types`
  pre-pass same as Phase 15.2 / 15.3 (concretizing binding type doesn't
  directly affect Wasm code but maintained for consistency). Added
  `examples/vec_codegen_wasm_typed.mere` (int / str / tuple / variant
  4 types = 252). Added 4 tests + rewrote existing Wasm rejection
  test (1185 passing). Now `Vec[R, T]` works on all 3 backends (C /
  LLVM IR / Wasm) — the constraint "Vec / OwnedVec / StrBuf / Map are
  interpreter-only" is fully gone for Vec[R, T]. Remaining: higher-order
  APIs / first-class value usage / OwnedVec / StrBuf / Map codegen
  remain interpreter-only (see DEFERRED §1.1).

- **Phase 15 #3: LLVM IR codegen supports `Vec[R, T]` (C feature
  parity)** — ported the same monomorphization pattern as Phase 15.2
  (C version) to LLVM IR. lib/codegen_llvm.ml: (1) added
  `vec_instances : (string, Ast.ty) Hashtbl.t`; (2)
  `emit_vec_runtime_for_llvm` emits one set per element type of
  `%mere_vec_<tag> = type { ptr, i32, i32, ptr }` + 4 helpers
  (`_new` / `_push` / `_get` / `_len`) (using LLVM's `getelementptr
  ... null, i32 1 → ptrtoint` idiom for sizeof(T), allocates via
  region; push's realloc within same region = arena semantics); (3)
  `llvm_ty_of` walks `TyCon ("Vec", args)`, returns Vec value as LLVM
  opaque ptr (`ptr`) and registers element type in `vec_instances`;
  (4) `ty_tag` catch-all relaxed to allow `TyRef _ R TyUnit` (region
  marker); (5) Var handler's vec_* rejection retained only for
  first-class value usage; (6) 4 special-cases (`vec_new` / `vec_push`
  / `vec_get` / `vec_len`) in emit_expr — `vec_elem_tag_of` reads
  element type; unwrap curried App (`App(App(Var "vec_push", v),
  x)`) and call `@mere_vec_<tag>_*`; `vec_new` pulls active region
  from `current_regions` and passes `@__lang_default_region` or
  `%__region_R`; (7) introduced `resolve_vec_let_types` pre-pass same
  as Phase 15.2 — connect let-poly generalized binding and use tyvars
  with `Typer.unify`; once any use site resolves, chain-propagates
  to all sites. Added `examples/vec_codegen_llvm_typed.mere` (mixes
  int / str / tuple / variant 4 types in one program; total 252).
  Added 5 tests (1182 passing) — confirms emit of mere_vec_T_new
  runtime for 4 patterns Vec[R, int] / str / tuple / region R inside.
  Remaining: Wasm backend Vec[R, T] (Phase 15.4 candidate) /
  higher-order APIs / first-class value / OwnedVec / StrBuf / Map.

- **Phase 15 #2: C codegen generalizes element type T of `Vec[R, T]`**
  — extends Phase 15.1 (`Vec[R, int]` only) to support any concrete
  element type supported by codegen: int / bool / str / tuple /
  record / variant. Monomorphize emits `mere_vec_<tag>` runtime struct
  + 4 helpers (`_new` / `_push` / `_get` / `_len`) per element type
  (e.g. `mere_vec_int` / `mere_vec_str` / `mere_vec_tuple_int_int` /
  `mere_vec_Tag`). lib/codegen_c.ml: (1) added `vec_instances` table;
  c_type_of / emit_expr register T encountered in Vec[_, T] sanitized
  via `ty_tag`; (2) `emit_vec_runtime_for : Ast.ty -> string` generates
  C runtime block per element type; (3) emit_expr's 4 special-cases
  (`vec_new` / `vec_push` / `vec_get` / `vec_len`) routed to
  `mere_vec_<tag>_*` helper names via `vec_elem_tag_of` helper; (4)
  `let v = vec_new () in body` generalized binding (Mere has no value
  restriction; generalized to `forall T. Vec[..., T]`) leaves App's
  own .ty TyVar unresolved; added `resolve_vec_let_types` pre-pass
  — for each `Let(P_var name, value, body)` where value.ty is Vec,
  connect all `Var name` in body to binding side via `Typer.unify`;
  once any use site (e.g. `vec_push v 10`) resolves, chain-propagates
  to all sites; (5) element type's C struct may be forward-referenced
  by later closure typedef etc.; insert `typedef struct mere_vec_<tag>
  mere_vec_<tag>;` forward typedef after tuple/record/variant bodies.
  Added `examples/vec_codegen_c_typed.mere` (mixes int / str / tuple /
  variant in one program; total 252). Added 2 tests + rewrote
  existing "Vec[R, <non-int>] reject" test to "str / tuple accept"
  (1178 passing). Remaining Vec codegen listed in §1.1 (higher-order
  APIs / first-class value / LLVM/Wasm / OwnedVec / StrBuf / Map).

- **Phase 15 #1: C codegen for `Vec[R, int]` (DEFERRED §1.1 partial
  resolution)** — first step toward native-izing interpreter-only Vec
  in the smallest scope (element type int / C backend only). Added
  `mere_vec_int` struct + `mere_vec_int_new / push / get / len`
  helpers to `lib/codegen_c.ml` runtime (region-allocated; push's
  realloc allocates new buffer in same region; old buffer reclaimed at
  region free = arena semantics). Fixed `c_type_of` to walk `Ast.walk`
  TyCon args, then map `TyCon ("Vec", [_; TyInt])` to
  `"mere_vec_int*"`. Added 4 special-cases to `emit_expr` `App`
  handler (`vec_new` / `vec_push v x` / `vec_get v i` / `vec_len v`)
  — vec_new reads active region binding via `Ast.walk e.ty` (outside →
  `__heap` = `__lang_default_region`; inside region R → `__region_R`)
  and expands to `mere_vec_int_new(&...)`. Remaining 3 unwrap curried
  form (`App (App (Var "vec_push", v), x)`) via inner/outer combo to
  runtime helper calls. Relaxed `ty_tag` catch-all rejection to pass
  only `TyRef` (region marker). Var handler's vec_* rejection kept
  only for first-class value usage (`let f = vec_new in ...`); direct
  application changed to pass. Added `examples/vec_codegen_c.mere`:
  returns 95 computing `vec_new () + push×5 + get / len` in
  outside-region (verified working via `clang` native binary). Added
  6 tests (1177 passing): C codegen accepts Vec[R, int]; runtime
  helpers emitted; binds to `__lang_default_region` outside / to
  `__region_R` inside; non-int like Vec[R, str] still rejected; LLVM
  / Wasm continue rejecting all Vec. Remaining Vec codegen listed in
  §1.1 (higher-order APIs / first-class value / LLVM·Wasm support /
  OwnedVec / StrBuf / Map / element types other than int).

- **Phase 14 #2: rename codebase from working name lang-ml → Mere** —
  followed Phase 14.1 name fixation (internal design notes) and
  changed code body / extensions / docs to Mere across the board. dune
  library `lang_ml` → `mere` (lib/dune); executable `main` → `mere`
  (bin/dune); `bin/main.ml` → `bin/mere.ml` (git mv); `Lang_ml.*` →
  `Mere.*` (bin/mere.ml / lib/codegen_llvm.ml / lib/repl.ml /
  test/test_basic.ml); examples/*.lang → *.mere (37 files, git mv);
  updated internal `.lang` references to `.mere` (comments in
  examples / `import "..."` paths / docs / repl_session.md); CLI
  usage `lang-ml` → `mere`; REPL startup message updated. Updated all
  Lang / lang-ml / `.lang` notation in docs / README / CLAUDE.md.
  Lang in sentences ("Lang program", "of Lang", etc.) also changed to
  Mere. Intentionally left design context directory `internal design
  notes` as-is (historical record). All 1171 tests pass. DEFERRED
  §7.1 (rename work) moved to fully resolved. Remaining GitHub repo
  rename (`lang-ml` → `mere`) is a user manual operation.

- **Phase 12 #10: reverse `owned_vec_to_vec` (DEFERRED §3.6 fully
  resolved)** — follows Phase 12.11 one-way (`vec_to_owned`) with
  reverse `owned_vec_to_vec : OwnedVec[T] -> Vec[R, T]`. Region R
  injected from `active_regions` at call site as App-handler
  special-case same as `vec_new` / `strbuf_new` / `map_new` (outside
  → `__heap` default). Eval is `Array.copy` for deep copy (V_vec
  shared, copy alone yields independence). 3-backend codegen
  interpreter-only stub. Verified: outside → `Vec[__heap, T]`;
  `region R { owned_vec_to_vec o }` → `Vec[R, T]` (escape check
  works); deep copy means subsequent owned-side push doesn't affect
  vec. Added 5 tests (1171 passing). DEFERRED §3.6 fully resolved.

- **Phase 13 #1: type error UX continued — did-you-mean for record
  field / view field / qualified name** — partially consumes DEFERRED
  §5.1. Switched `Field_get` family errors (view / record) and
  `Record_update` field mismatch errors in `lib/typer.ml` to go
  through `raise_with_suggestion`: passes the corresponding record /
  view's declared field name list as candidates and adds nearby names
  by Levenshtein distance as `did you mean \`X\`?` in help: message.
  **Qualified name typo** (e.g. `Math.factrial` → `Math.factorial`)
  needs no implementation change — when env lookup for `Var
  "Math.factrial"` fails, existing `Var` branch uses entire env
  (including M-prefixed bindings inside Module) as candidates and
  calls suggest_name, which works naturally. Verified: `Pt { name,
  value }` then `p.namee` → `did you mean \`name\`?`; same for view
  fields; same for `{ p | namee = ... }` record update;
  `Math.factrial 5` → `did you mean \`Math.factorial\`?`. Added 4
  tests (1166 passing). Remaining DEFERRED §5.1 (type variable
  rename hint / N-best candidate display) in separate slice.

- **Phase 12 #9: `vec_filter` / `vec_to_list` / `vec_to_owned`** —
  consumes DEFERRED §3.5 remainder and §3.6. Added 3 builtins:
  `vec_filter : Vec[R, T] -> (T -> bool) -> Vec[R, T]`
  (region-preserving, keeps only elements where predicate is true);
  `vec_to_list : Vec[R, T] -> T list` (converts to `'a list = Nil |
  Cons of 'a * 'a list`, builds Cons chain via `Array.fold_right`);
  `vec_to_owned : Vec[R, T] -> T OwnedVec` (`Array.copy` deep copy,
  returns OwnedVec independent of source — a way to extract
  region-internal Vec to heap). All schemes region-polymorphic;
  `vec_to_owned` result is drop_types-registered `OwnedVec` type so
  cannot be placed in region (`region R { ... vec_to_owned v ...
  &R ... }` auto-rejected as Trivial[R] violation). 3 backend
  codegen interpreter-only stubs for all 3 builtins. Added 10 tests
  (1162 passing): 3-scheme type inference; filter behavior / empty
  result; list conversion + empty Vec → [] display; deep copy to
  OwnedVec + independence from source mutations; region escape
  rejection. DEFERRED §3.5 fully resolved; §3.6 updated to one-way
  (Vec→Owned) resolved (reverse Owned→Vec needs region context,
  separate slice).

- **Phase 9 #5: precise import paths (importer-relative +
  canonicalisation)** — consumes DEFERRED §4.2. Phase 9.2 introduced
  cwd-relative `import "path";`; changed to **importer-relative**
  (resolved from the file containing the import statement). Added
  `Parser.current_base_dir : string ref`; `parse_program ?(base_dir =
  Sys.getcwd ())` for initial value. `import` branch: relative path
  via `Filename.concat !current_base_dir path`; canonicalized via
  `Unix.realpath`; during recursive parse swap `current_base_dir :=
  Filename.dirname canonical` (restored on exception). Added
  `?base_dir` to Pipeline.process; CLI (bin/main.ml) passes
  `~base_dir:(Filename.dirname path)` in file mode.
  Canonicalisation makes different relative forms (e.g. `/tmp/foo.mere`
  vs `./foo.mere`) refer to same file → accurate cycle guard.
  Verified: `import "./sub/inner.mere"` resolves from main.mere's dir;
  nested imports (main → middle → sub/inner) work from each step's
  dir; same file via different relative forms loaded once. Added 3
  tests (1152 passing). DEFERRED §4.2 updated to resolved.

- **Phase 9 #4: `type` / `record` declaration inside modules** —
  consumes last 1/3 of DEFERRED §4.1. Extracted T_type branch logic
  inside `parse_decls` (including record / variant / alias
  disambiguation) into helper `parse_type_decl_after_keyword`; added
  T_type branch to `parse_module_body` calling same helper. As a
  slice-1 limitation, **type / record / constructor names are not
  M-prefixed and enter global registry** — declaring same-named type
  in different modules conflicts (proper scoping in subsequent
  slice). Verified: `module M { type Pt = { x: int, y: int }; let mk =
  fn p -> Pt { ... } };` compute `p.x + p.y` from `M.mk (3, 4)`;
  `module M { type 'a opt = ... }; M.unwrap (S 42)` dispatches via
  variant; type and let mix OK. Added 3 tests (1149 passing). DEFERRED
  §4.1 fully resolved (3/3).

- **Phase 9 #3: nested modules + `open M;`** — consumes 2/3 of
  DEFERRED §4.1 (remaining: type / record inside module). Refactored
  `parse_module_body` to take `cur_path` parameter; handles `T_module
  T_ident inner T_lbrace` recursively. Registers both short name
  (`inner`) and full path (`outer.inner`) to `module_names`; qualified
  access from both inside and outside works. Newly added
  `module_bindings : (string, string list) Hashtbl.t` registry —
  inside `prefix_module_decls`, records direct binding names (only
  names without dots); used to expand `open M;`. Added `open` keyword
  + T_open token to lexer; added `T_open T_ident name T_semi` branch
  to parser's `parse_decls`: extract `module_bindings[m_name]` and
  expand to chain of `Top_let (P_var n, Var "M.n")` aliases;
  unregistered module is parse error. Nested module direct binding
  names containing dots are excluded from `open` expansion (e.g.
  `module M { module N { ... }; let g = ... }` with `open M;` brings
  in only `g`; N exports referenced as `M.N.foo`). Verified: `module M
  { module N { let f = ... }; let g = N.f + 1 }; M.N.f + M.g` works;
  shortcut access after `open M;` coexists with `M.foo` qualified
  access. Added `examples/module_nested.mere`. Tutorial 10.5 updated:
  nested + `open` usage + constraints. Added 7 tests (1146 passing).
  DEFERRED §4.1 updated to "2/3 resolved" (type / record inside
  module is future work).

- **Phase 11 #7: borrow checker refinement (3) — borrow propagation
  from match arms** — continues DEFERRED §2.2 (match patterns).
  Added Match case to `extract_borrows`: union of `extract_borrows`
  from each arm body (which arm runs is runtime-dependent, so
  conservatively treat all arms as active). Guards are side
  conditions so not subject to extraction. While we're at it,
  extended `Let_rec` / `With` / `Region_block` bodies to also
  traverse recursively (these values can leak borrows when
  let-bound). Verified: `let r = match v with | N -> &R x | S _ -> &R
  x in let m = &mut R x in 0` → conflict; `let r = match v with | N
  -> &R x | S _ -> &R y in let m = &mut R y in 0` → conflict (else
  branch equivalent &R y also active); unrelated `&mut R z` OK.
  Added 3 tests (1139 passing). Remaining borrow checker DEFERRED:
  §2.3 NLL only.

- **Phase 11 #6: borrow checker refinement (2) — borrow propagation
  through if branches** — consumes DEFERRED §2.2. Up through Phase
  11.5, only `Let (P_var _, Ref ..., body)` patterns added borrow to
  active set; couldn't detect cases where **if expression result
  leaks the borrow**, like `let r = if cond then &R x else &R y in
  ...`. Added helper `extract_borrows : Ast.expr -> (region * place *
  mode * loc) list`: Ref to single-element list; If(cond, t, e) to
  **union** of extracts from t/e; Let(_, _, body) recurse from body;
  Annot recurse from inner; otherwise empty list. Refactored
  `check_borrows` `Let` branch: pass value through `extract_borrows`
  to get borrows propagating up; conflict-check each one and add to
  active set; pass union to body. Verified: `let r = if c then &R x
  else &R y in let m = &mut R y in 0` → conflict (else branch from y
  also active); `let r = if c then &R x else &R y in let m = &mut R
  z in 0` → OK (z unrelated); nested let-in-if recurses properly.
  Added 5 tests (1136 passing). Next stage is §2.3 NLL
  (Non-Lexical Lifetimes) — releasing borrow at "the moment it stops
  being used", equivalent to liveness analysis.

- **Phase 11 #5: borrow checker refinement (1) — tracking complex
  expressions (field chain)** — consumes DEFERRED §2.1. Phase 11.4
  only tracked simple Var for `x` in `&[mode] R x`; extended to
  identify field chains like `p.field` / `p.q.r`. Added `place_id :
  Ast.expr -> string option` helper (Var → Some name, Field_get
  inner f → Some "<inner>.<f>", otherwise None). Replaced Var-only
  checks in `check_borrows` `Ref` / `Let` branches with place_id
  based. Non-place expressions (function call results, literals
  etc.) continue to be skipped (None). Error messages also display
  dotted paths like `&R p.x`. Verified: `&R p.x + &mut R p.x` →
  conflict; `&R p.x + &mut R p.y` → OK; `&R p.x + &R p.x` → OK
  (shared read each other); `&R o.inner.v + &mut R o.inner.v` →
  conflict (nested chain); `&R p + &mut R p.x` → OK (whole p and
  p.x are separate places). Added 6 tests (1131 passing). Remaining
  borrow checker DEFERRED: §2.2 control flow analysis (separate
  borrow sets per if branch) and §2.3 NLL in separate slices.

- **Phase 12 #8: `Map[R, K, V]` (region-aware mutable map)** —
  Minimum harness for design doc 13_region_std_types.md §5 `Map[R, K,
  V]`. Same construction-time binding pattern as Vec[R, T] /
  StrBuf[R]. Type is 3-arg `TyCon ("Map", [TyRef BorrowedRead R
  TyUnit; K; V])`. Eval has `V_map of (value, value) Hashtbl.t`
  (OCaml polymorphic hash/eq) + 5 builtins (`map_new` / `map_set` /
  `map_get` / `map_has` / `map_len`). `map_get` on missing key is
  eval error; `map_has` for safe check. Typer has 5 schemes
  (region / K / V each as TyVar for polymorphism); `types["Map"] =
  3`; `App (Var "map_new", _)` special-cased pulls region binding
  from active_regions (empty → __heap). Ast.pp_ty has 3-arg
  `Map[R, K, V]` bracket display (TyRef-of-unit / polymorphic both
  handled). Added `V_map` case to Phase 12.6 `len` builtin for
  polymorphic len. All 3 backend codegen interpreter-only stubs for
  Map type / 5 builtin names. Added `examples/map_basics.mere`:
  simple str→int, has-safe lookup, int→str (type reversal),
  short-lived inside region — 4 patterns demo. Tutorial 10.6 added
  Map API table + caveats (closure / ref as key identified per-ref).
  Added 10 tests (1125 passing): 5-scheme type inference; basic
  set/get; has branch; len with duplicate key; polymorphic type (int
  → str); eval error on missing key; region escape rejection;
  outside-region default; polymorphic len integration; codegen
  rejection. Now Q-010 main collections (Vec / OwnedVec / StrBuf /
  Map) all work in interpreter. Remaining: trait system proper
  (§3.1), unified Allocator trait API (§3.4), `OwnedVec` / `Vec`
  round-trip (§3.6), 3-backend codegen (§1.1).

- **Phase 12 #7: Vec higher-order APIs (iter / map / fold / set)** —
  Implemented higher-order functions intended for Vec API in design
  doc 13_region_std_types.md §3. All region-polymorphic + element
  type polymorphic. `vec_map` result Vec bound to same region as
  source (region-preserving). Schemes: `vec_iter : Vec[R, T] -> (T
  -> unit) -> unit`; `vec_map : Vec[R, T] -> (T -> U) -> Vec[R, U]`;
  `vec_fold : Vec[R, T] -> U -> (U -> T -> U) -> U`; `vec_set :
  Vec[R, T] -> int -> T -> unit`. Eval calls user functions
  (V_closure / V_builtin) via `apply_value_ref` pattern (same as
  `flip` / `try_or` / `iter_n` etc.); placement after apply_value_ref
  definition. `vec_set` is in-place mutation; out-of-range index is
  eval error. 3 backend codegen interpreter-only stubs for all 4
  names. Added `examples/vec_higher_order.mere`: int→int map /
  int→str map / fold for sum and max / set + iter / chain inside
  region — 5 patterns demo. Tutorial 10.6 section added higher-order
  API table + usage examples. Added 12 tests (1115 passing): 4-scheme
  type inference; map (incl. element type conversion); fold (sum);
  set + out-of-range; iter side effects via separate Vec;
  region-preserving behavior; codegen rejection. Remaining Q-010:
  Map[R, K, V]; Allocator trait; Vec / OwnedVec / StrBuf codegen
  support.

- **Phase 12 #6: `StrBuf[R]` (Q-010 narrowed — region-internal mutable
  string buffer)** — Minimum harness for design doc
  13_region_std_types.md §4 `StrBuf[R]`. Same construction-time
  binding pattern as `Vec[R, T]` (Phase 12.3); type is 1-arg
  `TyCon ("StrBuf", [TyRef BorrowedRead R TyUnit])` (region marker
  only, same convention as view types). Added `V_strbuf of Buffer.t`
  to eval (internal storage in OCaml Buffer); `to_string` formats as
  `StrBuf["..."]`. Builtins: `strbuf_new : unit -> StrBuf[R]`,
  `strbuf_push : StrBuf[R] -> str -> unit`, `strbuf_to_str : StrBuf[R]
  -> str`, `strbuf_len : StrBuf[R] -> int`. Added 4 schemes to typer
  in polymorphic-region form (TyVar in region position); pre-register
  `types["StrBuf"] = 1`; `App (Var "strbuf_new", _)` special-cased
  same as vec_new pulls region binding from active_regions (empty →
  __heap). Added polymorphic `StrBuf[a]` bracket display to
  `Ast.pp_ty`. Added `V_strbuf` case to Phase 12.6 `len` builtin for
  length via polymorphic. 3 backend codegen rejects both type /
  builtin as interpreter-only. Added `examples/strbuf_basics.mere`:
  outside-region (default `__heap`) / inside region (auto-bound to
  `StrBuf[R]`) / polymorphic `len` — 3 patterns demo. Tutorial 10.6
  updated: StrBuf[R] explanation + constraints. Added 9 tests (1103
  passing): type inference; push/to_str round-trip; empty len; inside
  region binding; escape rejection; polymorphic len integration;
  codegen rejection. Remaining Q-010: `Map[R, K, V]`; Allocator
  trait; Vec/OwnedVec/StrBuf codegen support.

- **Phase 12 #5: ad-hoc polymorphic `len` (Q-010 narrowed / lightweight
  unified trait-style API)** — Minimum practical alternative to a full
  trait system planned for `trait Collection { fn len(self) -> usize
  }` in design doc 13_region_std_types.md §6. Instead of introducing
  a full trait system (~500 LoC), added `len : 'a -> int` as an
  ad-hoc polymorphic builtin in the same frame as `show : 'a -> str`.
  Single scheme in typer (`'a -> int`); eval dispatches based on
  runtime value variant: `V_vec` (shared by Vec[R, T] and
  OwnedVec[T]) → array length; `V_str` → byte length; `V_tuple` →
  arity; `V_constr (Nil/Cons chain)` → list traversal counts
  elements; otherwise eval error. **Single API** for Vec[R, T] /
  OwnedVec[T] / `'a list` / `str` / `tuple`. 3 backend codegen
  reject `len` as interpreter-only stub. Added 8 tests (1094 passing):
  type inference; behavior for str / Vec / OwnedVec / tuple / list;
  eval error for unsupported value (int); codegen rejection. Full
  trait system introduction in future slice — whether trait's
  implicitness fully aligns with Mere's design philosophy (explicit >
  concise) is on hold.

- **Phase 12 #4: `OwnedVec[T]` (Q-010 narrowed (b) separate type)** —
  Implemented "separate type" portion of design doc
  13_region_std_types.md §9 "(b) separate type + trait for unified
  API". Added `OwnedVec[T]` (heap-allocated, has Drop) in contrast to
  `Vec[R, T]` (region-internal, Trivial). Added `owned_vec_new /
  push / get / len` schemes (1-arg, `'a OwnedVec` form) to typer;
  `types["OwnedVec"] = 1` + **registered in `drop_types`** so that
  region-placement triggers automatic rejection by
  `contains_drop_type` (`Trivial[R] violated: cannot place value of
  type \`'a OwnedVec\` into region — type contains a Drop type`).
  Eval shares `V_vec` (only type system treats them as different;
  internal implementation is the same mutable array). 3-backend
  codegen rejects both owned_vec_* builtins and OwnedVec type as
  interpreter-only (unified message `Vec / OwnedVec builtins are
  interpreter-only`). Added `examples/vec_vs_owned_vec.mere`:
  contrasts short-lived region Vec and long-lived OwnedVec in one
  program. Tutorial 10.6 updated: OwnedVec[T] explanation + how to
  choose vs Vec[R, T]. Added 6 tests (1086 passing): type of
  owned_vec_new; polymorphic push/get/len; region rejection via
  Drop; contrast that Vec[R, T] can be placed in region; 3-backend
  codegen rejection. Remaining Q-010: `StrBuf[R]` / `Map[R, K, V]`;
  unified Allocator trait API (trait-based unification of read API);
  Vec / OwnedVec codegen support.

- **Phase 12 #3: semantic backing for `Vec[R, T]` (Q-010 narrowed →
  implementation stage 3)** — Gives type system that actually tracks
  region to `Vec[R, T]` syntax that was parse-only in Phase 12.2.
  Changed Vec arity from 1 → 2; internal representation unified to
  `TyCon ("Vec", [TyRef BorrowedRead R TyUnit; T])` (region marker
  convention same as view types). Parser: `Vec[R, T]` emitted as
  2-arg; legacy `T Vec` (1-arg postfix) auto-filled with default
  region `__heap` and expanded to 2-arg form (forward-compat). With
  **TyVar in region position of scheme**, region-polymorphic APIs are
  realized through scheme machinery as-is (`vec_push : forall T
  R_marker. Vec[R_marker, T] -> T -> unit`); R_marker unifies with
  concrete region marker at call site. Added special handler to
  `Typer.infer` App case: `App (Var "vec_new", _)` reads innermost
  active_regions and directly binds region of `Vec[R, T]` (same
  shape as view construction); empty → `__heap`. Added bracket
  display for 2-arg Vec to `Ast.pp_ty` (`Vec[R, int]` / `Vec[__heap,
  'a]` / `Vec['a, 'b]` etc.). Verified: `vec_new ()` outside →
  `Vec[__heap, 'a]`; `region R { vec_new () }` → `Vec[R, 'a]` (escape
  is static error); `fn (v: Vec[R, int]) -> vec_len v` → `(Vec[R, int]
  -> int)`; `fn (v: int Vec) -> vec_len v` → `(Vec[__heap, int] ->
  int)`. Updated `examples/vec_basics.mere`: demonstrates auto-bind
  of region for `vec_new ()` inside region. Tutorial 10.6 updated:
  noted that region got semantic backing + explicit escape check.
  Added 3 tests + updated 7 existing tests to new format expectations
  (1080 passing). Remaining Q-010: explicit distinction from
  OwnedVec[T]; StrBuf[R] / Map[R, K, V]; unified Allocator trait API;
  Vec codegen support.

- **Phase 12 #2: `Vec[R, T]` syntax (Q-010 narrowed → implementation
  stage 2, lightweight)** — Forward-compatible slice that accepts
  the notation `Vec[R, T]` from design doc 13_region_std_types.md
  into parser. Added `T_ident name :: T_lbracket :: ...` branch to
  `simple_ty` in `lib/parser.ml` (name is uppercase): parses
  bracket-delimited argument list; region marker (bare uppercase
  ident yielding TyCon name=[]) dropped; remaining type arguments
  passed to `expand_alias_or_tycon name type_args`. Result is that
  `Vec[R, int]` is internally identical to `int Vec` (1-arg TyCon)
  — generates same TyCon. Region R is a documentation marker
  currently with no semantic backing (region-aware allocation /
  lifetime tracking implementation planned in future slice). Updated
  `examples/vec_basics.mere`: demonstrates `(vec_new () : Vec[R,
  int])` annotation inside region. Tutorial 10.6 section updated:
  `Vec[R, T]` syntax can now be written; current R is documentation
  only; both forms (`int Vec` / `Vec[R, int]`) produce equivalent
  types. Added 3 tests (1077 passing): type annotation parse; str
  version; `int Vec` and `Vec[R, int]` produce same type.
  Implementation scale: only ~25 lines added to parser.ml. Next
  slice (12.3) gives R semantic backing: reflect active_regions in
  vec_new return type (view construction pattern).

- **Phase 12 #1: `'a Vec` minimum harness (Q-010 narrowed →
  implementation stage 1)** — Adds basic variable-length vector as
  polymorphic builtin under name `'a Vec`, the most basic of design
  doc `13_region_std_types.md` region-version std types. Phase 12
  total (Vec[R,T] / OwnedVec[T] / StrBuf[R] / Map[R,K,V] / Allocator
  trait etc.) narrowed to MVP; syntax for region parameters in type
  and distinction from OwnedVec come in subsequent slices. Added
  `V_vec of value array ref` (storage in OCaml mutable array; push
  appends with reallocate) + 4 builtins (`vec_new : unit -> 'a Vec`,
  `vec_push : 'a Vec -> 'a -> unit`, `vec_get : 'a Vec -> int -> 'a`,
  `vec_len : 'a Vec -> int`) to `lib/eval.ml`; `to_string` formats as
  `Vec[...]`. Added 4 schemes (`vec_new_scheme` etc.) to
  `lib/typer.ml`; `Hashtbl.replace types "Vec" 1` pre-registers as
  arity-1 polymorphic type. Registered in `initial_env`. Trivial[R]
  check works because existing `contains_drop_type` walks
  recursively, so placing `Conn Vec` (where Conn is a drop type) in
  region is auto-rejected. Added explicit stubs to Var handlers of
  codegen (C / LLVM / Wasm) raising `Codegen_error` when they see
  `vec_new` / `vec_push` / `vec_get` / `vec_len` (all 3 backends
  emit `interpreter-only` message). Added `examples/vec_basics.mere`:
  basic operations on int / str Vec + Vec inside region demo. Added
  14 tests (1074 passing): type inference for 4 builtins; len of
  empty Vec; len/get after push; polymorphic (str Vec); region
  placement OK; Conn Vec rejected with Trivial[R]; eval error for
  out-of-range get; 3-backend codegen rejection. Future slice
  candidates: Vec[R, T] with region as parameter + Allocator trait
  + distinction from OwnedVec[T].

- **Phase 11 #4: borrow checker minimum harness** — Slice that
  consumes Q-004 "remaining implementation TODO". Added `check_borrows
  : (string * string * borrow_mode * Loc.t) list -> Ast.expr -> unit`
  to `lib/typer.ml`. Threads borrows for the same (region, var name)
  as active set through lexical scope; rejects coexistence of
  conflicting modes with `Type_error`. Coexistence allowed pairs
  defined in `borrows_compatible`: only shared read with shared read
  (`BorrowedRead` + `BorrowedRead`) and shared write with shared write
  (`SharedWrite` + `SharedWrite`); all else conflicts (`exclusive`
  family doesn't coexist with anything; shared read + shared write
  also rejected due to invalidation risk). AST walk: when discovering
  `Let (P_var p, Ref (mode, region, Var v_name), body)`, adds
  `(region, v_name, mode, value.loc)` to active set and recurses on
  body; free-standing `&[m] R v` also conflict-checks with active.
  `Pipeline.process` calls `Typer.check_borrows [] (Ast.desugar_program
  prog)` after `Typer.infer` to inspect program in one pass. Added
  `examples/borrow_conflict.mere` (intentional failure demo: taking
  `&mut R v` after `&R v`). Error message includes "previous borrow at
  line N, col N" note. Verified: `let a = &R v in let b = &mut R v` /
  `let a = &mut R v in let b = &mut R v` / `let a = &R v in let b =
  &shared write R v` / `let a = &exclusive R v in let b = &R v` all
  reject as conflict; `let a = &R v in let b = &R v` / 2 shared write
  / different variables OK. Added borrow checker explanation +
  conflict example output to `docs/tutorial.md` 10.4 section. Added 8
  tests (1060 passing). Currently tracking is limited to simple Var
  for `x` in `&[m] R x` — complex expressions (`&R rec.field` etc.)
  in future. Now Q-004 design (b) borrow annotation refinement is
  complete in both "can be written as types + machine-verifies
  conflict".

- **Phase 11 #3: auto-deref for field access through `&R T`** — At
  Phase 11.1 borrow annotation introduction, field access like
  `lg_ref.info "hi"` was crashing with `field access on non-record
  value`. Added `strip_refs` helper to `Field_get` case of
  `lib/typer.ml` (recursively peels TyRef wrappers); changed to
  perform existing view / record judgment on type after peeling.
  Borrow mode remains static contract; eval side already passed `&R
  v` through, so zero runtime changes. Result: method calls work
  directly through any of `&R Logger` / `&mut R Logger` / `&shared
  write R Logger`, like `lg.info "msg"`. Fully rewrote
  examples/borrow_modes.mere: rewrote signature-only demo to actually
  call cap methods (`log_action`, `db_run`, `show_config`) across
  borrow; prints `mk_logger`'s `[INFO]` output + DbHandle's `exec`
  call + AppConfig's `name`/`threads` read. Added 5 tests (1052
  passing): field access on Pt record through `&R`; through `&mut
  R`; through `&shared write R`; type inference for user-defined
  Lg11; type confirmation extracting field from `&R Lg11r`.

- **Phase 11 #2: borrow annotation realistic example + tutorial 10.4
  section** — Milestone showing "what is it good for" of the 4 modes
  added in Phase 11.1 (`&R T` / `&mut R T` / `&shared write R T` /
  `&exclusive R T`). Added `examples/borrow_modes.mere`: realistic
  demo constructing 3 kinds — Logger (shared write) / DbHandle
  (exclusive write) / AppConfig (shared read) — inside region, then
  borrowing each cap with appropriate mode and passing to handler.
  Run prints "[logged] save_order" / "[exclusive] UPDATE ..." /
  "[read]". Added `examples/borrow_modes_typeerror.mere`:
  **intentionally fails with type error** demo passing `&R db` to
  `&mut R DbHandle` parameter (displays as documentation that
  `expected \`&mut R DbHandle\`, got \`&R DbHandle\`` is shown).
  Added 10.4 "Borrow annotation" section to `docs/tutorial.md`
  (4-mode table + usage examples + mode mismatch error example +
  current limitations (borrow checker exclusion rules and `&R T`
  field auto-deref are future work)). Also added 2 new examples to
  section 12 examples list. No test count change (1047 still).
  Phase 11.1 brought "writable as type" state; Phase 11.2 brought
  "readable with understood meaning" state. Next slice candidates:
  borrow checker (exclusion rules) and `&R T` field auto-deref.

- **Phase 11 #1: borrow annotation refinement (Q-004 narrowed →
  implementation stage 1)** — Minimum harness for narrowing (b)
  borrow annotation refinement in design doc 08_effect_granularity.md
  down to implementation. Added `borrow_mode = BorrowedRead |
  SharedWrite | ExclusiveRead | ExclusiveWrite` to AST; signatures
  for `TyRef of borrow_mode * string * ty` (type level) and `Ref of
  borrow_mode * string * expr` (value level) changed to 3-arg. 4 new
  syntaxes in parser: `&R T` (default = BorrowedRead); `&mut R T`
  (ExclusiveWrite); `&shared write R T` (SharedWrite); `&exclusive R
  T` (ExclusiveRead). Value level `&R v` / `&mut R v` / `&shared
  write R v` / `&exclusive R v` similarly. `mut` / `shared` / `write`
  / `exclusive` are contextual keywords (regular idents in lexer;
  parser recognizes only after `&`). Typer's unify changed to require
  "region and mode equality" for `TyRef (m1, r1, t1) ↔ TyRef (m2,
  r2, t2)` (strict, no subtyping). pp_ty handles `&R T` / `&mut R T`
  / `&shared write R T` / `&exclusive R T`. Codegen (C / LLVM / Wasm)
  ignores mode — pointer representation is the same; only static
  guarantee. Verified: `fn (x: &mut R int) -> ...` type display OK;
  passing `&R 5` to `fn (x: &mut R int) -> 1` is type error
  `expected \`&mut R int\`, got \`&R int\``; calls with same mode
  pass; `(&R 5 : &mut R int)` annotation mismatch is type error.
  Logger problem (shared write representation) solved at syntax
  level; borrow checker (exclusion rules) in future slice. Added 14
  tests (1047 passing).

- **Phase 10 #1: aggregating where we are — tutorial / README / new
  examples / SUMMARY** — Milestone with 1033 tests / 3 backends /
  REPL / module / import in place; arranging outward-facing
  documentation. Added 10.5 "Modules and import" section and 11.5
  "Using the REPL" section to `docs/tutorial.md`; rewrote 13 "Native
  compilation" from C-only to 3-backend (C / LLVM / Wasm); updated
  closing remark from "memory model is not implemented in codegen"
  to "works in all backends". Full rewrite of `README.md`: status as
  of 2026-06-19 (1033 tests / 3 backend parity / module / import /
  REPL commands); added rows for module, import, REPL command, error
  UX to features table; added LLVM / Wasm build paths to build
  examples. New examples: `examples/module_basic.mere` (`module Math
  { let inc / square / pow / inc_then_square ... }` + shortened
  internal reference demo); `examples/lib_list_ops.mere` (decls-only
  library exporting `module ListOps { sum / length / map }`);
  `examples/import_demo.mere` (imports lib with `import
  "examples/lib_list_ops.mere";`); `examples/repl_session.md`
  (Markdown showing `:type` / `:env` / `:show` / `:load` / `:reset`
  / multi-line in dialog session format). Created new `internal
  design notes`: restructured destinations of Phases 1-9 as
  "outward-facing" (5-min status delivery to future self / sharing
  partners); aggregates feature coverage, history phase table,
  what's missing, next directions. No test count change (1033
  still).

- **Phase 9 #2: file split — `import "./other.mere";`** — Added
  `import` keyword + `T_import` token to lexer. Added
  `imported_files : (string, unit) Hashtbl.t` registry and
  `parse_decls` `T_import T_string path T_semi` branch to parser:
  reads target file with `In_channel.with_open_text`, recursively
  calls `Lexer.tokenize` + parse_program_internal, mixes resulting
  decls into current decl stream with List.rev_append (discards main
  expression). Skips same path if already registered (cycle
  prevention). Split `parse_program` into `parse_program_internal`
  (recursive worker) + `parse_program` (top-level wrapper, runs
  worker after `Hashtbl.reset imported_files`) — top-level cycle
  guard accumulator extends throughout recursive imports while being
  fresh per top-level call. Parser registries (constructors /
  records / module_names / aliases) are shared across recursive
  calls, so types / records / modules defined in imported files are
  visible from importer side. Verified: `import "/tmp/lib.mere";
  helper base` references helper / base from another file; `import
  "/tmp/lib_mod.mere"; Math.sq (Math.dbl 5)` qualifiedly references
  module in import; mutual `cyc_a ↔ cyc_b` imports yield a_val +
  b_val = 30 (no infinite loop thanks to cycle guard); diamond
  pattern (importing lib via both A and B) loads once without
  duplication; missing file is parse error. Added 6 tests (1033
  passing). Base path resolution is cwd-based; symlinks / different
  relative forms treated as different files (canonicalisation in
  future).

- **Phase 9 #1: minimum module harness — `module M { let f = ...; }`
  + `M.f` reference** — Next milestone for language surface. Added
  `module` keyword + `T_module` token to lexer; added `module_names :
  (string, unit) Hashtbl.t` registry and `parse_module_body` to
  `parser.ml` (slice 1: only `let` / `let rec`; terminates at
  `T_rbrace`); added `prefix_module_decls` (rewrites binding names
  and free Var references in body with `M.` prefix). Newly
  implemented `Ast.rename_free_vars`: shadowing-aware AST walker
  that excludes bind names computed by `pattern_vars` from shadow
  list in `Fun (param, ...)` / `Let (P_var p, ...)` body / `Let_rec
  [(n, _); ...]` / `With (n, ...)` body / `Match` arm patterns.
  Extended parser's `field_chain`: if lhs is `Var "M"` and `M ∈
  module_names`, emits `Var "M.f"` instead of `Field_get`. uppercase
  ident atom_base also checks `module_names` before constructor /
  record judgment. Added decls-only mode to `parse_program` (main =
  `()` if only T_eof); removed `Repl.prepare_input`'s `; ()` hack
  (made no-op, left as identity wrapper for compatibility).
  Verified: `module M { let answer = 42; let add = fn x -> fn y -> x
  + y; }; M.add M.answer 8` → 50; internal `inc (inc x)` shortened
  references rewritten as `M.inc (M.inc x)`; `let rec fact = fn n ->
  ... fact (n-1)` M.fact self-call works; `module M; module N;`
  same-name bindings don't conflict; `p.x` regular field access
  unchanged. In REPL also can write `module M { ... }` multi-line
  directly; `M.f` appears in `:env`. Added 7 tests (1027 passing).
  Types / records / nested modules in future slices.

- **Phase 8 #2: REPL continued — `:show NAME` + `:reset`** — Added 2
  new commands to `lib/repl.ml`. (1) `:show NAME` outputs type and
  value at once: `format_show eval_env type_env name` helper pulls
  scheme from `type_env` and `value ref` from `eval_env` respectively,
  returns string in `val NAME : TY\n  = VAL` format (uses
  `Eval.to_string`, so closures are `<closure:p>`, str is quoted,
  numbers / records / variants in same formatter). Unbound name
  yields `unbound name: NAME`. `print_show` is print entry of same
  content. (2) `:reset` rewinds both envs to
  `Eval.initial_env` / `Typer.initial_env` via `do_reset eval_env
  type_env`; displays `(envs reset)`. Added 2 lines to help text.
  Verified: `let x = 42; let g = "hi"; :show x` → "val x : int\n =
  42"; `:show g` → "val g : str\n = \"hi\""; `:show inc` (closure) →
  "val inc : (int -> int)\n = <closure:n>"; `:show nope` → "unbound
  name: nope"; after `:reset` env cleared, `:env` → "(no user
  bindings)". Added 5 tests (1020 passing; split I/O of
  `format_show` / `do_reset` to directly assert pure parts).

- **Phase 8 #1: REPL UX improvement — multi-line input +
  Diagnostic.format integration + :env / :load** — 4-point
  enhancement to `lib/repl.ml`. (1) Switched to loop accumulating
  multiple lines with `read_logical_input`: if tentative parse after
  input yields "error at T_eof location", treats as incomplete and
  prompts `..>` for continuation; returns `Some input` on parse
  success. `is_unfinished ~source` judges by whether `Parser.Parse_error`
  loc matches T_eof loc in tokenize result (`eof_loc` helper +
  `loc_eq`); `Lexer.Lex_error "unterminated string literal"` also
  treated as unfinished. Empty line in continuation is `(input
  aborted)`; line starting with `:` interrupts multi-line buffer for
  standalone command execution. (2) Replaced `format_exn` with
  `format_diag ~source`; passes each error (`Lexer / Parser / Typer
  / Eval`) through `Diagnostic.format ~source ~filename:"<repl>"` —
  REPL also displays with Rust-style code frame, same as file mode.
  (3) Added `:env` command: `user_bindings` helper excludes builtin
  names of `Typer.initial_env` and returns only user-added bindings
  in insertion order, listed as `val name : type`. (4) Added `:load
  FILE` command: reads file, adds decls to eval/type env through
  `process_decl`; displays added bindings as `val name : type` then
  `(loaded path)`. Updated help text for new commands. Verified: can
  directly write multi-line `let rec` like fib/factorial in REPL;
  type error `let x = 5 + "hi" in x` displays caret + help:;
  `:load /tmp/foo.mere` loads definitions and they can be confirmed
  with `:env`. Added 9 tests (1015 passing) — REPL helpers
  (probe_unfinished detects each pattern; user_bindings insertion
  order / empty user env).

- **Phase 7 #7: type error UX — hint expansion + App type error
  direction fix** — Expanded coverage of
  `Typer.type_conversion_hint`: (1) `expected int, got bool` → `use
  \`if b then 1 else 0\` to get an \`int\` from a \`bool\``; (2)
  `TyTuple ts1` vs `TyTuple ts2` arity mismatch → `tuple lengths
  differ — expected N element(s), got M`; (3) per-direction branching
  for `expected fn, got value` (extra arg / partial application);
  (4) `TyCon (n1, _)` vs `TyCon (n2, _)` name difference → `these
  are different named types (\`n1\` vs \`n2\`)`. Further restructured
  `Typer.infer` `Ast.App (f, arg)` case into 3 sub-cases: (a) `tf =
  Ast.TyArrow (param_ty, ret_ty)` → caret at arg.loc + `expected
  param_ty, got ta` via `unify arg.loc param_ty ta`; (b) `tf = TyVar
  _` → fresh var + whole unify as before; (c) others (extra arg case
  where `inc 3` portion of `int 3 4` is `int` etc.) → dedicated
  error `expected a function (\`'a -> 'b\`), got \`<actual>\`` +
  `help: you may be passing one too many arguments (...)`. Verified:
  `inc 3 4` → "expected a function, got int / help: too many
  arguments"; `add "hi" 3` → "expected int, got str / help: use
  str_len" (caret at arg.loc); `add 1 + 2` (= `add 1` arrives at
  int) → "expected int, got (int -> int) / help: missing an
  argument"; `true + 1` → "expected int, got bool / help: use if b
  then 1 else 0"; `f (1, 2, 3)` (where f is `(int, int) -> ...`) →
  "expected (int * int), got (int * int * int) / help: tuple lengths
  differ — expected 2, got 3"; distinct named records → "expected
  BarN, got FooN / help: different named types (BarN vs FooN)".
  Added 6 tests (1006 passing).

- **Phase 7 #6: type error UX — type conversion hint** — Added
  `Typer.type_conversion_hint t1 t2 -> string option` helper;
  appends `help: ...` after base message in unify error (via
  with_hint). Covered cases: `expected str, got int/bool` → `use
  \`show x\``; `expected int, got str` → `use \`str_len s\` ...`;
  `expected bool, got int/str` → `wrap in a comparison`; `expected
  fn, got value` → `you may be missing an argument`; `expected
  value, got fn` → `you may have passed a partially-applied
  function`. Other cases get no hint. Verified: `"answer: " ++ 42` →
  `help: use \`show x\``; `5 + "hi"` → `help: use \`str_len s\``;
  `if 1 then ... else ...` → `help: wrap in a comparison`. Added 4
  tests (**1000 passing — milestone**).

- **Phase 7 #5: type error UX — source span (caret range display
  with token width)** — Extended `Loc.t` from `{ line; col }` to
  `{ line; col; width }`; added `Loc.mk ?(width=1) ~line ~col ()`
  helper (default width = 1 for backward compatibility; `Loc.dummy`
  has width = 0). In lexer's `tokenize`, attached token char count
  to pos via `with_width pos w` at output of each token: identifier
  / tyvar / string literal / int literal / float literal / 1-3 char
  operator (existing kept at 1). In `Diagnostic.format`, extended
  caret to multiple chars with `String.make (max 1 width) '^'`;
  applied bold-red ANSI color to all carets. Verified: in `let y = x
  + "hello"` error from `^` alone to `^^^^^^^^^^` (10 chars); in
  `factrial` identifier error to `^^^^^^^^` (8 chars); in `add
  "hello"` `add` to `^^^` (3 chars). Added 3 tests (996 passing).

- **Phase 7 #4: type error UX — ANSI coloring** — Added
  `Diagnostic.use_color : bool ref` (default false); CLI
  (`bin/main.ml`) sets to `true` when `Unix.isatty Unix.stderr &&
  not NO_COLOR`. `ansi`/`red`/`blue`/`cyan`/`bold`/`bold_red`/`bold_cyan`
  helpers selectively insert escape codes (`\027[CODEm ...
  \027[0m`). In Diagnostic.format, kind is bold-red; line number,
  `|`, `-->`, `=` in gutter are blue; caret `^` is bold-red; help:
  / note: keywords are bold-cyan. When `use_color = false`,
  everything passes through (test compatibility). Also respects
  NO_COLOR env var (https://no-color.org/). Verified: when run via
  TTY (via `script`), colored; plain when piped; plain when
  `NO_COLOR=1`. Added 5 tests (993 passing).

- **Phase 7 #3: type error UX — suggesting typo corrections via
  Levenshtein** — Added `Typer.levenshtein` (edit distance
  calculation, O(la*lb) DP), `Typer.suggest_name` (`max_dist` based
  on length, 3/2/1), `Typer.with_hint` / `raise_with_suggestion`
  helpers. Changed Type_error raises in `unbound variable` / `unknown
  constructor` / `unknown record type` (both in expression and in
  pattern) to go through `raise_with_suggestion`; appends `help: did
  you mean \`<name>\`?` if there's a close candidate. Extended
  `Diagnostic.format`: splits msg by `\n`; headline goes beside
  caret of code frame; rest (help:/note:) renders after code frame
  in `= help: ...` format. Verified: `factrial + 1` (factorial in
  scope) → "unbound variable: factrial / help: did you mean
  `factorial`?"; `Greeen` (Color = Red | Green | Blue) → "unknown
  constructor: Greeen / help: did you mean `Green`?"; `zzzzzz` (no
  close name) → no hint. Distance threshold adjusts by name length
  (stricter for short names); tie-break prefers shorter. Added 4
  tests (988 passing).

- **Phase 7 #2: type error UX — "expected X, got Y" form + audit of
  unify call order** — Changed `Typer.unify` error wording from
  `"type mismatch: \`X\` vs \`Y\`"` to `"expected \`X\`, got \`Y\`"`
  (X=expected, Y=actual). At the same time, **unified `unify loc t1
  t2` calls across Typer to `(expected, actual)` order**: primitive
  type checks for Neg / Bin (+, -, *, /, %, ++) / Logic / If
  condition swapped to `unify ... Ast.TyXxx actual` (TyXxx=expected);
  Fun annotation `unify t' alpha` (annotation=expected); Match guard
  `unify TyBool tg`; each Match arm `unify result_var tb` (first arm
  is expected); Record_lit / Record_update field `unify exp_ty t`
  (declared=expected); Field_get / Record_update base `unify
  result_ty t_base`. Constr arg `unify exp ta` (param=expected).
  Symmetric cases (`==` lhs/rhs; if branch then/else; P_or bs1/bs2;
  let-rec alpha vs body) preserve meaningful order. Pattern checks
  (P_int/Bool/Str/Unit/constr/tuple/record) were originally `unify
  expected XXX` (scrutinee=expected) so no change needed. App
  preserves original `unify tf (TyArrow (ta, result))` (recursive
  structural unify compares tf.param and ta yielding "expected
  param_ty, got arg_ty"). Verified: `let y = x + "hello"` →
  "expected `int`, got `str`"; `add "hi"` (add: int->int) →
  "expected `int`, got `str`"; `if cond then "yes" else 42` →
  "expected `str`, got `int`"; record field → "expected `int`, got
  `str`". Added 4 tests (984 passing).

- **Phase 7 #1: type error UX improvement — Rust-style code frame**
  — Rewrote `Diagnostic.format` in `lib/diagnostic.ml` to Rust-style
  multi-line code frame: header (`kind: msg`); location pointer
  `--> filename:line:col`; line-numbered margin (`1 | ...`); caret
  + message below error line (`  | ^ ...`); context of 2 lines
  before + 1 line after. Changed terminal error message of
  `Typer.unify` from `"cannot unify X with Y"` to `"type mismatch:
  \`X\` vs \`Y\`"` (type names enclosed in backticks, neutral
  order). At zero-loc, 1-line fallback as before. Verified: `let y =
  x + "hello"` displays as `type error: type mismatch: \`str\` vs
  \`int\` --> file:2:13 | 1 | let x = 5 in | 2 | let y = x +
  "hello" in | | ^ type mismatch: ... | 3 | y`. Parse error / unbound
  variable error etc. output in common format. Added 6 tests (980
  passing). Phase 7 started — improving language surface developer
  experience.

- **Phase 6 #12: Wasm codegen special-cases `'a list` show in
  `[a, b, c]` form** — Wasm version of LLVM Phase 5.14. In
  `emit_show_fn`'s variant branch, processes `TyCon ("list",
  [elem_ty])` as special-case before others: loop scan with cur /
  acc / first / tag / pl / h locals. `block $end` + `loop $lp`
  loads tag from head, break on Nil; on Cons, loads payload (tuple
  offset) → head = `i32.load offset=0 payload` → concat `, ` if
  needed (first flag) → concat `show_<elem_tag>(h)` → cur = tail =
  `i32.load offset=4 payload` → loop. After end, concat `]`.
  `[` / `]` / `, ` deduped via `intern_show_str`. Verified (wat2wasm
  + Node.js): `show [1, 2, 3]` → `[1, 2, 3]`; `show (Nil : int
  list)` → `[]`; `show ["hello", "world"]` → `["hello", "world"]`.
  Added 3 tests (974 passing). **3 backends (C / LLVM / Wasm) fully
  parallel — the same Mere program runs on each of 3 backends as
  native binary / WAT**.

- **Phase 6 #11: Wasm codegen show general builtin** — Wasm version
  of LLVM Phase 5.12. Wasm has no `asprintf` equivalent so **all
  hand-rolled**: `show_int` performs int→decimal string conversion
  on Wasm (allocates 16-byte buffer from bump pointer → writes digits
  right-to-left → prepends `-` if needed → returns pointer to first
  digit); `show_bool` registers `true` / `false` in data segment and
  branches with `select`; `show_str` is 2-stage concat wrapping with
  `"`; `show_unit` is const offset of `()`; `show_tuple_X_Y`
  concatenates `(`, each element show, `, `, `)` via
  `__lang_str_concat`; `show_<R>` concats `R { f1 = `, each field
  show, `, f2 = `, ` }`; `show_<V>` is tag dispatch (nested
  if/else of `i32.load + i32.eq`) → each ctor: data ptr direct if
  nullary; concat `ctor_name + " "` + recursive payload show if
  payload. `show_types` Hashtbl + `collect_show_types` +
  `add_show_type` registers types + recursively registers dependent
  types (cycle guard). `subst_params` helper applies args of
  polymorphic record/variant (Wasm also emits separate function per
  mono instance; layout is shared). `intern_show_str` dedupes
  literals to save data segment. `App (Var "show", arg)` dispatches
  to `call $show_<ty_tag arg.ty>`. Verified (wat2wasm + Node.js):
  `show 42` → "42"; `show true` → "true"; `show "hi"` → "\"hi\"";
  `show (1, "hi")` → `(1, "hi")`; `show (SS 42)` → "SS 42"; `show
  (Pt { x = 3, y = 4 })` → `Pt { x = 3, y = 4 }`; `show (Cons (1,
  Cons (2, Cons (3, Nil))))` → `Cons (1, Cons (2, Cons (3, Nil)))`
  (recursive variant works naturally). Added 8 tests (971 passing).
  `'a list` special-case `[a, b, c]` form in future slice.

- **Phase 6 #10: Wasm codegen complex patterns (P_int / P_str /
  P_bool / P_unit / P_record / P_as / nested ctor / or / guard)** —
  Wasm version of LLVM Phase 5.11. Rewrote `compile_pat` as fully
  recursive `(cond_local_slot, bindings)` function: P_int →
  `i32.eq`; P_bool → `i32.eq`; P_str → `call $__lang_streq` (new
  runtime helper, byte-by-byte compare yielding i32 boolean);
  P_unit → constant true; P_record → declared field order
  `i32.load offset` + sub-pattern recurse (handles both record /
  view); P_as → inner pattern + whole value bind; P_tuple → each
  element `i32.load offset=i*4` + recurse; P_constr → tag test
  (`i32.load offset=0 + i32.eq`) + sub-pattern recurse (nested OK).
  Multiple sub-tests chained with `combine_and` helper via
  `i32.and`. Or-patterns pre-flattened with `expand_or`. Guard
  evaluated in arm's bindings scope, AND with cond, short-circuit
  with `if/else` (no guard eval if cond is false). Added
  `@__lang_streq` runtime helper (block + loop with sequential
  byte_a / byte_b compare). Verified (wat2wasm + Node.js): `match 3
  with | 0 -> 100 | 1 -> 200 | _ -> 300` → 300; `match "hello" with
  | "hi" -> 1 | "hello" -> 2 | _ -> 9` → 2; `match Cons (SS 5,
  Nil) with | Cons (SS n, _) -> n` → 5 (nested ctor); `match Pt { x
  = 3, y = 4 } with | Pt { x = a, y = b } -> a + b` → 7; `(a, b) as
  p → fst p + snd p + a + b` → 6; `LCgA | LCgB -> 1` → 1 (or);
  `when n < 10 -> 200` → 200 (guard). Added 8 tests (963 passing).

- **Phase 6 #9: Wasm codegen polymorphic variant / record + recursive
  variant + P_tuple sub-pattern** — Wasm memory layout is uniform
  (every value is i32 = 4 bytes), so LLVM-style (Phase 5.9 / 5.10)
  monomorphization is not needed. `'a opt`, `'a Box`, `'a list = Nil
  | Cons of 'a * 'a list` all work via same code path as mono
  variant/record. Removed `params <> []` check in `Constr` and
  `r_params <> []` check in `Record_lit` (Wasm doesn't emit
  type-specific struct typedefs, so same code works for
  multi-instantiation). To expand `'a list` Cons (tuple payload
  `('a, 'a list)`) in Match, added `P_tuple` sub-pattern to
  `compile_pat` equivalent in `Match`: loads each element from
  payload tuple offset via `i32.load offset=i*4` into fresh local and
  binds (`Cons (h, t)` → h, t each loaded into separate locals).
  Verified (wat2wasm + Node.js): `type 'a opt; match LSome 42 with
  | LSome n -> n` → 42; `type 'a Box; let bi = Box { v = 42 } in let
  bs = Box { v = "hi" } in str_len bs.v + bi.v` → 44; `type 'a list;
  sum [1,2,3,4,5]` → 15; `length ["a","b","c","d"]` → 4. Added 4
  tests (955 passing). Wasm backend's advantage: layout uniformity
  makes monomorphization unnecessary.

- **Phase 6 #8: Wasm codegen Region_block + Ref + with Drop + view
  construction + Unit_lit** — Wasm version of LLVM Phase 5.13.
  Wasm's linear memory + `__lang_bump` global already acts as one
  region, so user's `region R { body }` is implemented in LIFO: save
  current value of `__lang_bump` to local at entry → evaluate body
  → stash result in another local → restore bump to saved value →
  push result back. This way allocations within region scope are
  "freed" at scope end (subsequent allocations can overwrite as bump
  pointer returns). `Ref (R, v)` (`&R v`) evaluates inner + bump
  4-byte alloc + `i32.store offset=0` + push base. `With (c, v,
  body)` saves v to local + evaluates body + after body, if v's
  record has `close: unit -> unit` field, pulls env/fn_idx from
  closure value via `i32.load` + auto-invokes with `i32.const 0`
  (unit arg) + `call_indirect (type $cl)`, drops result, pushes
  body value. `view V[R] of T { ... }` Record_lit handled
  separately by view-name (same memory layout as record, bump alloc
  + i32.store); Field_get of view value uses field index from
  `Typer.views.v_fields` with `i32.load offset=idx*4`. `Unit_lit` →
  `i32.const 0`. Verified (wat2wasm + Node.js): `region R { let x =
  &R 5 in 42 }` → 42; `with c = mk 7 in c.id * 10` (close prints
  "closing") → 70; `view Cell[R] of int { v: int }; region R { let
  c = Cell { v = 7 } in c.v }` → 7. Added 6 tests (951 passing).
  **Wasm backend covers all memory model features, on par with C /
  LLVM**.

- **Phase 6 #7: Wasm codegen first-class fn + closure** —
  Wasm-specific constraint handling: function pointers are not
  memory ptr but **function table indexes**; indirect calls go
  through `call_indirect (type $sig)`. Declared `(type $cl (func
  (param i32) (param i32) (result i32)))` at module top; adapters
  registered in table starting from index 0 via `(table N funcref)`
  + `(elem (i32.const 0) ...)`. closure value is 8-byte memory
  struct `{ env_offset, fn_table_idx }`. Auto-generated env-ignoring
  adapter `(func $f_closure (param i32) (param i32) (result i32)
  local.get 1; call $f)` for each top-level fn `f` + table
  registration; recorded index in `fn_closure_table_idx`. At `Var
  name` value position, if `fn_closure_table_idx` is registered,
  memory-allocs closure value (`env=0, fn_idx=N`) and pushes.
  Indirect App: save closure to local → load env / arg / load
  fn_idx → `call_indirect (type $cl)`. Anonymous Fun: compute free
  variables via `free_vars` → capture only those registered in
  `locals` → register fresh adapter `anon_N_fn` in table → push to
  `pending_closures` queue → at construction site, memory-alloc env
  (store each capture in sequence), alloc closure value + push.
  Adapter body entry loads captures from env into local slots via
  `i32.load offset=N*4` before evaluating body. Drain loop in
  emit_program processes pending. Added `pattern_vars` + `free_vars`
  helpers. Verified (wat2wasm + Node.js): `let inc = fn x -> x + 1
  in let apply = fn f -> f 5 in apply inc` → 6; `(make_adder 5) 10`
  → 15; `compose inc dbl 5` → 11; `twice inc 5` → 7. Added 7 tests
  (945 passing).

- **Phase 6 #6: Wasm codegen variant + match (monomorphic, single
  payload type)** — Variants also laid out in linear memory:
  4 bytes (`{ i32 tag }`) if nullary-only; 8 bytes (`{ i32 tag, i32
  payload }`) if payload. `variant_tags : (cname, int) Hashtbl`
  populated at start of emit_program from `Exhaustive.type_variants`;
  `variant_payload_ty` helper detects payload type (single type
  shared by all payload-bearing ctors; Codegen_error if differ).
  Compiled `Constr cname (arg)` to bump alloc + `i32.store offset=0`
  (tag) + (if needed) `i32.store offset=4` (payload) + push base.
  `Match` saves scrut to local, loads tag/payload via `i32.load
  offset=0/4`; each arm compiles to nested chain of `local.get tag;
  i32.const N; i32.eq; if (result i32) ... else ... end`; fallthrough
  traps with `unreachable`. Pattern subset: P_constr / P_var / P_wild;
  payload bind uses payload local slot. Verified (wat2wasm +
  Node.js): `type Color = R | G | B; match G with | R -> 0 | G -> 1
  | B -> 2` → 1; `type Stat = Ok | Err of str; match Err "boom" with
  | Ok -> 0 | Err msg -> str_len msg` → 4; `let v = ISome 42 in
  match v with | INone -> 0 | ISome n -> n` → 42. Added 6 tests
  (938 passing). guard / polymorphic / recursive / nested pattern /
  or-pattern continue to be Codegen_error (future slices).

- **Phase 6 #5: Wasm codegen record (monomorphic)** — Same linear
  memory layout as tuple (Phase 6.4). Stores `Record_lit (name,
  fields)` in `Typer.records.r_fields` **declaration order**
  (reconstructed even if source field order differs): base = bump →
  immediately advance bump by 4*N (reserve) → write each field via
  `i32.store offset=i*4` → push base. `Field_get (inner, fname)`
  pulls index from record name of inner type → `i32.load
  offset=idx*4`. `Record_update (base, updates)` allocates new
  buffer with bump; for each field, writes new value if in updates,
  else copies from source via `i32.load offset=...`; returns base of
  new buffer. Functions that take / return record also work
  naturally (record is also passed as i32 offset; signature
  unchanged). Verified (wat2wasm + Node.js): `type Pt = { x: int,
  y: int }; let p = Pt { x = 3, y = 4 } in p.x + p.y` → 7;
  `{ p | x = 100 }.x * .y` → 400; record-returning fn `let mk = fn
  x -> Pair { a = x, b = str_len x } in print ((mk "hello").a)` →
  "hello". Polymorphic record / view continue to be Codegen_error
  (future slices). Added `wasm_with_decls` test helper. Added 4
  tests (932 passing).

- **Phase 6 #4: Wasm codegen tuple** — Tuple laid out in linear
  memory: each element 4 bytes (Mere int / bool / str all in i32 /
  offset representation). `Tuple [e1; e2; ...]` construction: base
  offset = bump; bump += 4*N immediately reserves memory area; write
  each element via `i32.store offset=N*4` at base-relative
  position; finally push base. Important to reserve first — nested
  tuple or `++` inner emit advances bump further (during
  implementation, fixed bug where `((1,2), 3)` summed to 22 because
  reserve was after writing). `fst` / `snd` builtin dispatched to
  `i32.load offset=0` / `offset=4`. Tuple-arg / tuple-return
  functions also work naturally (tuple is i32 offset, no signature
  change). Verified (wat2wasm + Node.js): `let p = (1, 2) in fst p
  + snd p` → 3; `let p = ("hello", 42) in print (fst p)` → "hello";
  `((1, 2), 3)` sum → 6; tuple-arg fn `sum_pair (10, 20)` → 30.
  Added 5 tests (928 passing).

- **Phase 6 #3: Wasm codegen string support** — Implemented
  architecture for handling strings via Wasm's linear memory.
  `(memory (export "memory") 1)` declares 1-page (64 KB) memory +
  exports; `(global $__lang_bump (mut i32) (i32.const N))` is bump
  pointer for dynamic alloc (mutable global). `Str_lit` lifted as
  `(data (i32.const offset) "...\00")` data segment;
  `wasm_string_escape` escapes `\HH`. `fresh_str_offset` helper
  assigns unique offset to each literal; accumulates in
  `str_data_decls` ref. `$__lang_strlen` (block + loop searches null
  byte) and `$__lang_str_concat` (2 strlen calls + 2 copy loops +
  null terminator + bump update) defined inline in WAT (emitted as
  runtime_helpers in one go). `print s` delegated to host (Node.js)
  via host import `(import "env" "puts" (func $puts (param i32)))`;
  value is i32 0; Node.js side accesses memory to decode +
  console.log. `str_len s` dispatched to `call $__lang_strlen`; `++`
  to `call $__lang_str_concat`. Functions taking / returning str
  also work naturally (Wasm also treats str as i32, so signature
  unchanged). Verified (wat2wasm + Node.js with puts that decodes
  memory): `str_len "Hello, world!"` → 13; `str_len ("hello, " ++
  "world!")` → 13; `print "Hello, Wasm!"` → "Hello, Wasm!"; `let
  greet = fn name -> "Hello, " ++ name ++ "!" in print (greet
  "world")` → "Hello, world!". Added 9 tests (923 passing).

- **Phase 6 #2: Wasm codegen function lifting + recursion** — Top-
  level `let f = fn x -> ...` and `let rec` lifted as `(func $f
  (param i32) (result i32) ...)`. `fn_skel` / `lift_fn_skels` /
  `find_concrete_arrow` / `resolve_fn_types` implemented in
  `codegen_wasm.ml` in parallel, same shape as LLVM Phase 5.2.
  `emit_fn_def` puts each fn in independent locals/instrs scope:
  param in slot 0 (Wasm positional locals); let bindings minted as
  slot 1, 2, ...; `local_counter` / `locals` / `instrs` saved /
  restored per-fn. Compiled `App (Var name, arg)` to `<arg push>` +
  `call $name` (only names registered in `toplevel_fn_names` get
  direct call). Wasm allows forward reference in same module, so
  C/LLVM-style forward declaration / mutual recursion special
  handling not needed. Verified (wat2wasm + Node.js): `factorial 10`
  → 3628800; `fibonacci 15` → 610; `is_even 7` (mutual recursion) →
  0. Added 5 tests (914 passing).

- **Phase 6 #1: Wasm (WAT) codegen MVP** — Started on the third
  design target (Wasm). Implemented `emit_program : ?main_ty:ty ->
  Ast.program -> string` in new `lib/codegen_wasm.ml`; emits subset
  (int / bool / arith / cmp / logic / Neg / If / Let (P_var) / Var /
  Annot) as WAT (WebAssembly Text format, S-expression form). Wasm
  is a stack-based VM (different from LLVM's SSA) — each expression
  pushes operands in sequence, opcode consumes from stack + pushes
  result. Compiled `Bin (op, a, b)` to sequential `emit_expr a;
  emit_expr b; <opcode>`. `If` to `if (result i32) ... else ... end`
  block. `Let (P_var n, value, body)` to combination of `(local
  i32)` (fresh slot assignment) + `local.set N` + `local.get N`.
  Comparison via `i32.lt_s` / `i32.gt_s` / `i32.eq` etc.; bool
  widened to i32 (`i32.const 0/1`); `Neg` expressed as `0 - x`.
  `main` function emitted as `(func $main (export "main") (result
  i32))`; local decls consolidated at function head. Added `-w <file>`
  / `-we <expr>` flags to CLI; `infer_program` helper shared across
  3 backends (C/LLVM/Wasm). Verified (via wat2wasm `.wasm` binary +
  Node.js `WebAssembly.instantiate`): `let a = 10 in let b = 20 in
  if a + b > 25 then a * b else 0` → 200; `if 3 > 2 then 100 else
  200` → 100; `let x = 5 in x * x + 1` → 26; `true && (false ||
  true)` → 1. Added 14 tests (909 passing). Functions / strings /
  record / variant / closure / region etc. in subsequent slices of
  Phase 6.

- **Phase 5 #14: LLVM IR codegen `'a list` show special-case
  (`[a, b, c]` form)** — Equivalent to C codegen Phase 4.16.
  Special-cases `TyCon ("list", [elem_ty])` (when recursive list)
  before variant branch in `emit_show_fn`: scans from head with
  alloca/load/store + loop blocks (`loop_test` / `loop_body` /
  `loop_iter` / `loop_end`); stringifies each element via
  `show_<elem_tag>`; concats with `", "` between via
  `__lang_str_concat`; appends `"]"` at end. Pre-registers
  `@.s_lbracket` ("["), `@.s_rbracket` ("]"), `@.s_comma_space` (",
  "). Side: (1) `add_show_type` registers in
  `mono_variant_instances` / `mono_record_instances` when
  encountering polymorphic TyCon (struct typedef emitted for cases
  like `show (Nil : int list)` where mono instance can't be
  collected via Constr); (2) `collect_tuple_shapes` end walks
  substituted payload of mono variant instances (emits tuple shape
  of Cons payload `(int, int list)` of `int list` even without Cons
  in AST); (3) moved `collect_show_types` before typedef emission
  (so instance flow propagates correctly). Verified (clang native):
  `show [1, 2, 3]` → `[1, 2, 3]`; `show (Nil : int list)` → `[]`;
  `show ["hello", "world"]` → `["hello", "world"]`. Added 4 tests
  (895 passing). **Phase 5 (LLVM backend) covers all C codegen
  (Phase 4) features** — int / fn / str / tuple / record / variant /
  closure / region / poly / recursive variant / complex pattern /
  show / all memory model / list pretty-print.

- **Phase 5 #13: LLVM IR codegen Region_block + Ref + with Drop +
  view construction + Unit_lit** — Implemented all Mere memory-model
  features in LLVM backend in one slice; equivalent to C codegen
  Phase 4.17 user-side region + 4.18 with Drop + 4.19 view
  construction. `current_regions : (name * register) list ref`
  tracks region scope. Compiled `Region_block (R, body)` to `alloca
  %__lang_region` + `__lang_region_init(ptr, 1MB)` + body +
  `__lang_region_free`. Compiled `Ref (R, v)` (`&R v`) to inner
  evaluation + sizeof (`getelementptr null` + `ptrtoint`) +
  `__lang_region_alloc` + `store` to write to region buffer; ptr
  return. `With (c, v, body)`: `let c = v` + body evaluation; after
  body, if v's record has `close: unit -> unit` field, auto-invokes
  via `c.close.fn(c.close.env, 0)` (`extractvalue` separates closure
  value → env/fn + call). At `Record_lit`, if `name in Typer.views`,
  view construction: get region name from `e.Ast.ty`'s `TyCon (V,
  [TyRef (R, ...)])` → build record value with `insertvalue` in
  declaration order → place in region with `__lang_region_alloc` +
  `store` → ptr return. At `Field_get`, if inner type is
  `is_view_type`, `getelementptr %V, ptr %x, i32 0, i32 idx` +
  `load` to get field. Added `TyRef _ → ptr` and `TyCon (n, _) when
  Typer.views n → ptr` to `llvm_ty_of`. `Unit_lit` emitted as `i32
  0` (needed for `fn () -> ()`). Verified (clang native): `region R
  { let x = &R 5 in 42 }` → 42; `region R { let pair = &R (1, 2) in
  99 }` → 99; `type Pt = { x: int }; region R { let p = &R Pt { x =
  42 } in 100 }` → 100 (record also placeable in region); `drop
  type Conn = { id, close }; with c = mk 7 in c.id * 10` → "close
  7\n70" (close called correctly at scope end); `view Cell[R] of
  int { v: int }; region R { let c = Cell { v = 7 } in c.v }` → 7.
  Added 7 tests (891 passing). **LLVM backend covers all memory-
  model features, on par with C backend (Phase 4.21)**.

## 2026-06-17

- **Phase 5 #12: LLVM IR codegen show general builtin** — LLVM
  version of C codegen Phase 4.12. Specializes `show : 'a -> str`
  per-call from arg type's `show_<ty_tag>`; generates dedicated
  function for each type. Added `@asprintf(ptr, ptr, ...)` to
  runtime_decls. `show_types` Hashtbl + `collect_show_types` walks
  AST to find `App (Var "show", arg)`; `add_show_type` recursively
  registers arg type + dependent types (tuple elem / record field /
  variant payload), with Hashtbl guard so recursive variant `'a
  list` etc. doesn't infinite-loop. `emit_show_fn` emits specialized
  fn per type: int → `@asprintf("%d", x)`; bool → `select i1` for
  `@.s_true` / `@.s_false`; str → `@asprintf("\"%s\"", x)`; unit →
  const `@.s_unit`; tuple → call each element `show_T` →
  `@asprintf("(%s, ..., %s)", ...)`; record (mono / poly) → each
  field show + `@asprintf("Type { f = %s, ... }", ...)`; variant
  (mono / poly / recursive) → tag dispatch (icmp eq + br + phi) →
  each ctor: `@.s_ctor_<name>` direct if nullary; recursive payload
  show + `@asprintf("Ctor %s", ...)` if payload. Format strings and
  ctor name strings pre-registered at start of emit_program for what
  is needed (`mint_show_global` / `mint_show_format` helpers). `App
  (Var "show", arg)` dispatched to `call ptr @show_<ty_tag
  arg.ty>(arg)`. Verified (clang native): `show 42` → "42"; `show
  "hi"` → "\"hi\""; `show true` → "true"; `show (1, "hi")` → `(1,
  "hi")`; `show (SS 42)` → "SS 42"; `show (Pt { x = 3, y = 4 })` →
  `Pt { x = 3, y = 4 }`; `show (Cons (1, Cons (2, Cons (3, Nil))))`
  → `Cons (1, Cons (2, Cons (3, Nil)))`. Added 9 tests (884
  passing). `'a list` special-case `[1, 2, 3]` form (equivalent to
  Phase 4.16) in future slice.

- **Phase 5 #11: LLVM IR codegen complex patterns (P_int / P_str /
  P_bool / P_unit / P_record / P_as / nested / or / guard)** — LLVM
  version of C codegen Phase 4.14 + 4.15. Rewrote `compile_pat` as
  fully recursive `(test_cond, bindings, var_types)` function: P_int
  → `icmp eq i32`; P_bool → `icmp eq i1`; P_str → `@strcmp(ptr,
  ptr)` + `icmp eq i32 result, 0`; P_unit → constant `1`; P_record
  → declared field order `extractvalue` + sub-pattern recurse;
  P_as → inner pattern + whole value bind; P_tuple → each element
  `extractvalue` + recurse; P_constr → tag test + sub-pattern
  recurse (payload via GEP+load if recursive variant, else
  extractvalue). Multiple sub-tests chained via `and_cond` helper
  with `and i1`. Or-patterns pre-flattened with `expand_or` (typer
  guarantees both branches' bound names match, body duplicable).
  Guard evaluated in arm's bindings scope; if true → body, if false
  → next_label (= try next arm). Added `@strcmp` to runtime_decls.
  Verified (clang native): `match 3 with | 0 -> 100 | 1 -> 200 | _
  -> 300` → 300; `match "hello"` str match → 2; `match Cons (SS 5,
  Nil)` nested ctor → 5; `match Pt { x=3, y=4 } with | Pt { x=a,
  y=b }` → 7; `(a, b) as p` → 6 (`P_as`); `match LCgB with | LCgA
  | LCgB -> 1 | LCgC -> 2` → 1 (or); `match 7 with | n when n < 5
  -> 100 | n when n < 10 -> 200 | _ -> 300` → 200 (guard). Added 8
  tests (875 passing).

- **Phase 5 #10: LLVM IR codegen recursive variant + P_tuple sub-
  pattern** — Switched variants with self-referential payload (`type
  ilist = INil | ICons of int * ilist`, `'a list = Nil | Cons of 'a
  * 'a list`) to heap-allocated node + ptr representation.
  `recursive_variants` set + `variant_is_recursive` /
  `mono_variant_is_recursive` helpers for judgment. Populated in 2
  stages within emit_program: at decl registration (source-level) +
  at mono instance collection (substituted). `emit_variant_typedef`
  / `emit_mono_variant_typedef` emit `%V_node = type { i32, T }`
  (on-heap node) if recursive; `llvm_ty_of` returns `ptr` if name in
  recursive_variants, so value type is transparent ptr. `Constr`
  recurse: `__lang_region_alloc` allocates node in default region;
  `getelementptr` + `store i32 tag` + `getelementptr` + `store T
  payload` write; ptr return. `Match` recurse: get tag from
  scrutinee ptr via `getelementptr` + `load i32`; payload of each
  arm similarly via `load`. In pattern compile, expand `P_tuple`
  sub-pattern (`Cons (h, t)`) into chain of `extractvalue` of
  payload tuple struct; bind each element to fresh register.
  `pattern_var_types` helper adds concrete types of pattern bind
  names to current_var_types (so polymorphic recursive calls don't
  leave `'a list` as-is). Match scrutinee type fallback to
  current_var_types if Var; same for direct-call App arg type.
  Reordered typedef emission to `collect_mono_instances` + recursive
  judgment → tuple/record/variant typedef emit (so recursive_variants
  state affects tuple emit). Verified (clang native): `type ilist =
  INil | ICons of int * ilist; sum (ICons (1, ICons (2, ICons (3,
  INil))))` → 6; `type 'a list = Nil | Cons of 'a * 'a list; sum
  [1,2,3,4,5]` → 15; `length ["a","b","c","d"]` → 4 (poly recursive
  list). Added 5 tests (867 passing).

- **Phase 5 #9: LLVM IR codegen monomorphization of polymorphic
  variant / record** — C codegen Phase 4.11 + 4.13 implemented on
  LLVM side in one slice. `polymorphic_variants` /
  `polymorphic_records` Hashtbl defer declarations (walk
  `Exhaustive.type_variants` + `Typer.records` at start of
  emit_program; register only poly ones); recover poly variant param
  names via constructor's `params`. `mono_variant_instances` /
  `mono_record_instances` accumulate found instances;
  `collect_mono_instances` walks AST + fn signature to find
  `(name, args)`. `subst_params` / `subst_variants` substitute type
  vars → concrete types; `mono_variant_name n args` /
  `mono_record_name n args` produce specialized names (`opt_int`,
  `Box_str` etc.). `emit_mono_variant_typedef` determines payload
  type from substituted payload type via `variant_payload_ty_of`;
  emits `%opt_int = type { i32, T }`. `emit_mono_record_typedef`
  emits `%Box_int = type { ... }` with substituted field types.
  `llvm_ty_of (TyCon (n, args))` maps to mono name if name in
  `polymorphic_variants/records`. `Constr` emit: pull mono name from
  `e.ty`; determine payload type with `variant_payload_ty_of`.
  `Record_lit` / `Field_get` / `Record_update` similarly use
  `mono_record_name` + substituted fields for poly records. `Match`
  scrutinee type, if poly, uses mono name + substituted variants.
  Verified (clang native): `type 'a LCgOpt = LCgN | LCgS of 'a;
  match LCgS 42 with | LCgN -> 0 | LCgS n -> n` → 42; `type 'a Box
  = { v: 'a }; let b = Box { v = 42 } in b.v` → 42; specialize both
  types `let bi = Box { v = 42 } in let bs = Box { v = "hi" } in
  str_len bs.v + bi.v` → 44 (both `%Box_int` and `%Box_str` emitted).
  Added 7 tests (862 passing). Recursive poly variant (`'a list`)
  requires recursive variant support → Phase 5.10.

- **Phase 5 #8: LLVM IR codegen default region runtime + closure/
  string alloc via region** — Implemented work equivalent to C
  codegen Phase 4.17 + 4.20 + 4.21 on LLVM side in one slice.
  `%__lang_region = type { ptr, ptr, i64 }` struct + `@__lang_default_region
  = internal global %__lang_region zeroinitializer` file-scope
  global + 3 helper functions `__lang_region_init/alloc/free`
  defined inline in LLVM IR (`region_runtime_helpers`).
  `__lang_region_alloc` uses 8-byte aligned bump pointer (`(n + 7) &
  -8` implemented with `and i64 ..., -8`; advances top via gep i8,
  store). Calls `__lang_region_init(@__lang_default_region,
  4194304)` (4 MB) at `@main` entry; calls `__lang_region_free`
  before final `ret i32 0`. Replaced `malloc` in `__lang_str_concat`
  with `__lang_region_alloc(@__lang_default_region, ...)`; closure
  env (anonymous Fun) `malloc(sizeof)` similarly replaced. Added
  `@free` to runtime_decls; inserted region_runtime_helpers in emit
  order right before str_concat_helper. Verified (clang native):
  `(make_adder 5) 10` → 15; `compose inc dbl 5` → 11; concat like
  `"hello, " ++ "world"`; only `malloc` call in generated IR is one
  spot inside region init (one-shot free at program end, valgrind
  clean). Added 8 tests (855 passing). LLVM backend memory model
  reached the same level as C backend (Phase 4.21).

- **Phase 5 #7 Phase B: LLVM IR codegen anonymous Fun + closure-
  with-captures** — Handles internal `fn x -> ...` in expression
  position. Computes free variables of AST with `free_vars` /
  `pattern_vars` helpers (excluding bound names, preserving order);
  filters to those registered in `current_var_types` (excluding top-
  level / builtin). For each capture, gets concrete type from
  `current_var_types`; generates `%anon_N_env = type { T1, T2, ...
  }` env struct typedef; pushes `anon_N_fn` adapter to
  `pending_closures` queue. At construction site: allocates env with
  `malloc(sizeof(%anon_N_env))` (LLVM `getelementptr null` trick +
  `ptrtoint` calculates size); writes each capture to env field via
  `getelementptr %env, ptr %p, i32 0, i32 idx` + `store`; assembles
  closure value with `insertvalue %closure undef, ptr %env, 0` +
  `insertvalue ..., ptr @anon_N_fn, 1`. `emit_anon_adapter` invoked
  by `emit_program` draining `pending_closures` (iterative loop also
  processes new pending added during drain); in adapter body entry
  block, pulls each capture from env_self with `getelementptr` +
  `load` into fresh register, binds to env, then emits original Fun
  body. Added `current_expected_ty : ty option ref`: lets parent
  context type serve as fallback when AST's Fun.ty is polymorphic
  (resolves cases where inner Fun's type stays `'a -> 'a` in
  let-poly curried polymorphic HOFs like `fn f -> fn x -> f (f
  x)`; emit_fn_def / emit_anon_adapter set return_ty at body start
  / restore at end). Extended Let case to add value type to
  current_var_types (so closure can capture variables of outer let).
  Verified (clang native): `let make_adder = fn n -> fn x -> x + n
  in (make_adder 5) 10` → 15 (capture); `let twice = fn f -> fn x
  -> f (f x) in twice inc 5` → 7 (curried HOF + polymorphic); `let
  apply = fn f -> fn x -> f x in apply (fn n -> n * 3) 7` → 21
  (anon Fun passed as arg); `let compose = fn f -> fn g -> fn x ->
  f (g x) in ((compose inc) dbl) 5` → 11 (3-level nested closure +
  2 captures). Added 7 tests (847 passing). env currently leaks via
  `@malloc` — default region-ization in future slice.

- **Phase 5 #7 Phase A: LLVM IR codegen first-class top-level fn** —
  Lowers `T1 -> T2` type as `%closure_T1_T2 = type { ptr, ptr }`
  (env, fn pointer). `closure_struct_name` helper for closure type
  name; `collect_arrow_types` walks AST + fn signatures to gather
  all used arrow types; `emit_closure_typedef` generates typedef.
  Auto-generates env-ignoring adapter `define T2 @<name>_closure_fn
  (ptr %env_unused, T1 %x) { ret T2 @<name>(T1 %x); }` for each
  top-level fn (`emit_closure_adapter`). At `emit_expr` `Var name`:
  if no shadowing in env and registered in `toplevel_fn_names`,
  inline-constructs closure value with `insertvalue %closure undef,
  ptr null, 0` + `insertvalue ..., ptr @<name>_closure_fn, 1`. `App
  f arg`: existing direct-call path preserved (for known top-level
  fn); otherwise dispatches via `extractvalue %closure %c, 0/1` to
  get env/fn, then `call T2 %fn_ptr(ptr %env, T1 %arg)` (no fn
  pointer type cast needed via opaque pointer). Added
  `current_var_types : (string * ty) list ref`: for polymorphic Var
  in fn body (parameter staying as `'a -> int` after let-poly), can
  pull concrete type from resolve_fn_types-derived (sets param's
  concrete ty at start of `emit_fn_def`, save/restore). Verified
  (clang native): `let inc = fn x -> x + 1 in let apply = fn f -> f
  5 in apply inc` → 6; `let apply2 = fn f -> f (f 5) in apply2
  inc` → 7. Added 7 tests (840 passing). Anonymous Fun (inner `fn
  x -> ...`) and closure-with-captures (Phase B) in separate slice.

- **Phase 5 #6: LLVM IR codegen variant + match (monomorphic, single
  payload type)** — Lowers monomorphic variant to LLVM named struct:
  if all ctors nullary, `%V = type { i32 }`; if payload exists, `%V
  = type { i32, T }` (`variant_payload_ty` detects single payload
  type shared by all payload-bearing ctors; Codegen_error if differ).
  `variant_tags` Hashtbl holds constructor → int tag; set as side
  effect of `emit_variant_typedef`. `collect_variant_names` walks
  AST + fn signature + Constr's type_name to gather used variant
  types (only `Typer.types` arity 0 ones). `Constr cname arg_opt`
  → `%t0 = insertvalue %V undef, i32 tag, 0` → optional `%t1 =
  insertvalue %V %t0, T arg, 1` chain constructs SSA struct value.
  `Match` gets scrutinee's tag with `extractvalue %V %s, 0`; tests
  each arm sequentially with `icmp eq i32 %tag, N` + `br i1`;
  fallthrough is `@abort()` + `unreachable`; merges all arm results
  with `phi <result_ty>` at end. Pattern is P_constr / P_var /
  P_wild only; payload bind creates payload register with
  `extractvalue %V %s, 1` and adds to bindings. Added @abort
  declaration to runtime_decls. Verified (clang native): `type Color
  = R | G | B; match G with | R -> 0 | G -> 1 | B -> 2` → 1; `type
  Status = Ok | Err of str; match Err "boom" with | Ok -> 0 | Err m
  -> str_len m` → 4; `type IntOpt = INone | ISome of int; let v =
  ISome 42 in match v with | INone -> 0 | ISome n -> n` → 42. Added
  9 tests (833 passing). Guard / polymorphic variant / recursive
  variant / nested pattern / or-pattern continue to be Codegen_error.

- **Phase 5 #5: LLVM IR codegen record (monomorphic)** — Lowers
  monomorphic record (`type Pt = { x: int, y: int }`) to LLVM named
  struct (`%Pt = type { i32, i32 }`). Added `TyCon (name, []) when
  Hashtbl.mem Typer.records name -> "%" ^ name` to `llvm_ty_of`;
  `record_fields` / `field_index` helpers pull declaration-order
  fields from `Typer.records`. `Record_lit` emit constructed with
  `insertvalue` chain in declaration order (even if source field
  order differs from declared, pulls values with `List.assoc_opt`
  and stacks in declaration order). `Field_get` is `extractvalue %R
  %p, idx`; `Record_update` starts from base value and stacks each
  update field via `insertvalue`. `collect_record_names` walks AST
  + fn signature to gather all used record types (polymorphic
  records excluded for now, separate slice). `emit_record_typedef`
  generates `%Name = type { T1, T2, ... }`. Via `bin/main.ml`
  `infer_program` helper, so Typer.records is already populated.
  Added `llvm_with_decls` test helper (parallel to
  `codegen_with_decls`). Verified (clang native): `type Pt = { x:
  int, y: int }; let p = Pt { x = 3, y = 4 } in p.x + p.y` → 7;
  Record_update `{ p | x = 100 }` x * y → 400; record-returning fn
  `let mk = fn x -> Pair { a = x, b = str_len x } in print ((mk
  "hello").a)` → "hello". Added 6 tests (824 passing). Polymorphic
  record (`type 'a Box`) stays Codegen_error.

- **Phase 5 #4: LLVM IR codegen tuple** — Lowers tuple to LLVM named
  struct (`%tuple_int_str = type { i32, ptr }`). `ty_tag` /
  `tuple_struct_name` helpers (same naming convention as codegen_c
  generates symbols like `tuple_int_str`); `collect_tuple_shapes`
  walks AST + fn signature to gather all used tuple types;
  `emit_tuple_typedef` generates `%name = type { T1, T2, ... }`.
  `Tuple` node emit constructs struct value in SSA register with
  `insertvalue` chain (starts from `undef`, stacks each element via
  `insertvalue %T %prev, Tn vn, idx`). `fst` / `snd` builtin
  compiled to `extractvalue %tuple_X %p, 0/1` (struct name resolved
  from arg's `.ty`). `llvm_ty_of (TyTuple ts)` returns
  `%<tuple_struct_name>`, so tuple-arg / tuple-return function
  signatures automatically take correct form (`define %tuple_int_int
  @split(ptr %s)`, `define i32 @sum_pair(%tuple_int_int %p)`).
  Nested tuple (`((1, 2), 3)` → `%tuple_tuple_int_int_int = type {
  %tuple_int_int, i32 }`) auto-generated. Verified (clang native):
  `let p = (1, 2) in fst p + snd p` → 3; `let p = ("hello", 42) in
  print (fst p)` → "hello"; `let split = fn s -> (s, str_len s) in
  print (fst (split "hello"))` → "hello"; nested tuple `((1,2), 3)`
  sum → 6; tuple-arg fn `sum_pair (10, 20)` → 30. Added 8 tests
  (818 passing).

- **Phase 5 #3: LLVM IR codegen strings + print + ++ + str_len +
  str-taking/returning functions** — Maps `TyStr` to LLVM `ptr`
  (opaque pointer). Lifts `Str_lit s` as private constant global
  `@.str_N = private constant [N x i8] c"...\00"`; generated via
  `fresh_str_global` helper; escapes non-printable ASCII with `\HH`.
  Uses global symbol directly as ptr for value (no GEP needed with
  opaque pointer). Compiles `Bin (Concat, a, b)` to `call ptr
  @__lang_str_concat(ptr %a, ptr %b)`; `__lang_str_concat` defined
  inline in LLVM IR (combination of `malloc` + `strlen` + `memcpy`
  + GEP + `store i8 0`). Compiles `print` builtin to `call i32
  @puts(ptr %s)` (discards return value; Mere value is 0); `str_len`
  to `call i64 @strlen(ptr %s)` + `trunc i64 ... to i32`. Added
  `TyStr → ("ptr", "%s")` to `main_format_of`; generates `@.fmt_s =
  c"%s\\0A\\00"` global. str-taking/returning functions auto-lowered
  correctly (`define ptr @f(ptr %s)`). Runtime helpers (`declare ptr
  @malloc(i64)` etc.) and `__lang_str_concat` body emitted in
  emit_program in one go; `.ll` file is self-contained. Verified
  (clang native): `print "Hello, LLVM!"` → "Hello, LLVM!"; `"hello,
  " ++ "world!"` → "hello, world!"; `str_len "Hello, world!"` →
  13; `let greet = fn name -> "Hello, " ++ name ++ "!" in print
  (greet "world")` → "Hello, world!"; `let exclaim = fn s -> s ++
  "!" in print (exclaim "wow")` → "wow!"; `let pick = fn n -> if n
  > 0 then "positive" else "negative" in print (pick 5)` →
  "positive". Added 10 tests (810 passing).

- **Phase 5 #2: LLVM IR codegen function lifting + recursion** —
  Lifts top-level `let f = fn x -> ...` and `let rec f = ... and g
  = ...` as LLVM `define iXX @f(iYY %x) { ... }`. Implemented
  `fn_skel` / `lift_fn_skels` / `find_concrete_arrow` /
  `resolve_fn_types` in `codegen_llvm.ml` in parallel, same shape
  as C codegen (combined with LLVM-specific `llvm_ty_of`).
  `emit_fn_def` emits each function as independent SSA scope
  (`reg_counter` / `label_counter` reset per-function; `instrs`
  save/restore). At `App (Var name, arg)`, if `name` is registered
  in `toplevel_fn_names`, compiled to `%t = call iZZ @name(iYY
  %arg)` (closure-as-value in future slice). LLVM IR allows forward
  reference within same module, so forward declaration needed in
  Phase 4 is unnecessary (mutual recursion works as-is). Verified
  (clang native): `factorial 10` → 3628800; `fib 15` → 610;
  `is_even 7` (mutual recursion) → 0. Added 6 tests (800 passing).

- **Phase 5 #1: LLVM IR codegen MVP** — Started second backend that
  compiles Mere to native binary. Implemented `emit_program :
  ?main_ty:ty -> Ast.program -> string` in new
  `lib/codegen_llvm.ml`; converts subset (int / bool / arith / cmp
  / logic / Neg / If / Let (P_var) / Var / Annot) to LLVM textual
  IR. Hand-written text generation (no dependency on opam's `llvm`
  package; directly compile with `clang out.ll`). Name management
  via SSA register counter (`%t0`, `%t1` ...) and basic block label
  counter; If goes through `br i1` + label/phi; comparison via
  `icmp slt/sgt/eq/...`; bool computed in `i1` and zext-extended to
  `i32` at main end for output via `@printf` (`@.fmt_d =
  c"%d\\0A\\00"`). Added `-ll <file>` / `-lle <expr>` flags to CLI;
  shared infer_program helper for both C / LLVM backends. Verified
  (clang native execution): `let a = 10 in let b = 20 in if a + b
  > 25 then a * b else 0` → 200; `if 3 > 2 then 100 else 200` →
  100; `let x = 5 in x * x + 1` → 26; `true && (false || true)`
  → 1. Added 15 tests (794 passing). Functions / strings / record /
  variant / closure / region etc. now Codegen_error (same scope as
  Phase 4 MVP).

- **Phase 4 #21: strings + recursive variant nodes also moved to
  default region** — Unifies remaining 2 malloc sites under
  `__lang_default_region`. Replaced `malloc(la + lb + 1)` in
  `__lang_str_concat` runtime helper with `__lang_region_alloc
  (&__lang_default_region, la + lb + 1)`; replaced
  `malloc(sizeof(T_node))` in recursive variant Constr emit
  (self-referential variant like `Cons (h, t)`) with
  `__lang_region_alloc(&__lang_default_region, sizeof(T_node))`.
  Reordered helper ordering in `emit_program` to
  `region_runtime_helpers → str_concat_helper` so str_concat helper
  can reference `__lang_default_region` symbol (ordering issue).
  Now the only remaining malloc on C side is base buffer allocation
  inside `__lang_region_init`; all user-visible alloc sites ride on
  bump arena. Batch free with `__lang_region_free(&__lang_default_region)`
  at `main` end; valgrind clean. Verified (clang native): `let
  greet = fn name -> "Hello, " ++ name ++ "!" in print (greet
  "world")` → "Hello, world!"; `sum [1, 2, 3, 4, 5]` → 15 (Cons of
  recursive list all in region alloc). Added 2 tests + updated 1
  (779 passing; renamed "Constr mallocs node" to "Constr uses
  default region").

- **Phase 4 #20: closure env moved to default region** — Added
  program-lifetime arena `__lang_default_region` at file scope
  (`static __lang_region __lang_default_region;`); calls
  `__lang_region_init(&__lang_default_region, 1 << 22)` (4MB) at
  start of `main`, `__lang_region_free` at end. Switched anonymous
  closure env struct alloc from `malloc(sizeof(...))` to
  `__lang_region_alloc(&__lang_default_region, sizeof(...))`.
  Closures can outlive user's `region R { ... }` (carried out like
  `make_adder 3 |> add3 4`), so don't coexist with user region;
  needed to be in separate program-lifetime arena. Per-closure
  malloc cost gone; batch-freed at `main` end; valgrind also clean.
  Verified (clang native): `let make_adder = fn n -> fn x -> n + x
  in let add3 = make_adder 3 in add3 4` → 7; `let compose = fn f
  -> fn g -> fn x -> f (g x) in compose (fn n -> n + 1) (fn n -> n
  * 2) 5` → 11 (nested closure with captures all in default
  region). Remaining leaks: string concat (`++`) and recursive
  variant node (`Cons`). Added 5 tests + `assert_no_contains`
  helper (777 passing).

- **Phase 4 #19: region-izing view construction** — Codegen places
  `view V[R] of T { ... }` on region's bump allocator. View value
  represented in C as `V*` (pointer type); at construction,
  allocates in region via `__lang_region_alloc(&__region_R,
  sizeof(V))`, copies content, returns pointer. `c_type_of (TyCon
  (V, [TyRef R TyUnit])) -> V*`; `is_view_type` helper distinguishes
  record / view; `Field_get` uses `->` for view value. View value's
  lifetime matches region scope (combined with Phase 2.1 escape
  check + Phase 4.17 region runtime) — **memory model's view
  feature works fully at runtime level**. Verified (clang native):
  `view Cell[R] of int { v: int }; region R { let c = Cell { v = 7
  } in c.v }` → 7. Added 3 tests (772 passing; added Top_view
  handling to codegen_with_decls helper).

- **Phase 4 #18: `with` Drop execution codegen + typedef ordering
  cleanup** — C codegen for `with c = v in body`: at scope end,
  auto-calls c's `close` field via `c.close.fn(c.close.env, 0)`
  (only when `close: unit -> unit` field exists in Drop type; skip
  if absent. Multiple `with` are nested in AST, so naturally LIFO).
  Side: reorganized typedef structure to "all forward decls →
  closure typedefs → all struct bodies". Logic: for cases where
  record has `closure_T1_T2` type like `close: unit -> unit` field
  of Drop type, closure typedef needs record's full definition as
  function-pointer return; but C can use forward-declared struct as
  function pointer return type, so closure typedef can be emitted
  if forward decls come first. Split all variant / record / tuple
  typedefs into 2 stages of forward decl + body; reorder them in
  emit_program. Verified (clang native): `drop type Conn = { id:
  int, close: unit -> unit }; let mk = fn id -> Conn { id = id,
  close = fn () -> print ("close " ++ show id) } in with c = mk 7
  in c.id * 10` → "close 7\n70" (close called correctly at scope
  end). Added 3 tests + updated 6 typedef snapshots to new format
  (769 passing).

- **Phase 4 #17: region runtime (bump allocator)** — Codegen
  `region R { body }` as a real bump allocator. Added new C
  runtime helper `__lang_region` (`{ char* base; char* top; size_t
  cap; }`) + `__lang_region_init/alloc/free` injected into
  generated source. `emit_expr Region_block` outputs statement
  expression `({ __lang_region __region_R; __lang_region_init
  (&__region_R, 1<<20); __auto_type __r_result = body;
  __lang_region_free(&__region_R); __r_result; })`. `emit_expr Ref
  (R, v)` emits `({ __auto_type __ref_v = v; typeof(__ref_v)* __p
  = __lang_region_alloc(&__region_R, sizeof __ref_v); *__p =
  __ref_v; __p; })` (bump alloc + copy + return pointer in region).
  `c_type_of (TyRef _ inner)` to `inner*`. Combined with escape
  check (typer), memory is batch-freed on region scope exit, but
  type signature guarantees `&R T` doesn't leak (Phase 2.1 escape
  check) for safety. **Milestone where memory model went from "type
  level label" to "real bump allocator"**. Verified (clang
  native): `region R { let x = &R 5 in 42 }` → 42; `region R { let
  pair = &R (1, 2) in 99 }` → 99; `type Pt = { x: int }; region R
  { let p = &R Pt { x = 42 } in 100 }` → 100 (record also placeable
  in region). Added 5 tests (766 passing).

- **Phase 4 #16: `'a list` show in `[a, b, c]` form + variant
  payload tuple shape collection** — Special-cases `TyCon ("list",
  [elem_ty])` in `emit_show_fn`; generates specialized function
  that strings the whole list with a while loop (`"[]"` if Nil;
  `[1, 2, 3]` format if Cons; matches Mere interpreter output).
  Side: extended tuple shape collection to include mono variant
  payload (`tuple_int_list_int` etc. referenced even in cases like
  `show ([] : int list)` that doesn't include Cons construction;
  fixed build failure where necessary struct typedef wasn't
  emitted). Verified (clang native): `show [1, 2, 3]` → `[1, 2,
  3]`; `show ["hello", "world"]` → `["hello", "world"]`; `show
  ([] : int list)` → `[]`. Added 2 tests (761 passing).

- **Phase 4 #15: C codegen or-pattern + match guard** — Flattens
  `| pat1 | pat2 -> body` into multiple arms via pre-pass
  `expand_or` of Match emit (constraint that both branches bind
  same name set guaranteed by typer). Body is duplicated to both
  but safe as pure expression. `when ...` guard evaluated in arm's
  bindings scope; falls through if false (`test ? ({ bindings;
  guard ? body : next; }) : next`). Verified (clang native): `type
  Col = R | G | B; match G with | R | G -> 1 | B -> 2` → 1; `match
  7 with | n when n < 5 -> 100 | n when n < 10 -> 200 | _ -> 300`
  → 200. Nested or-pattern (constructor etc. inside or) continues
  to be Codegen_error. Added 4 tests + updated 1 (759 passing;
  replaced "guard rejected" with "guard accepted").

- **Phase 4 #14: C codegen complex patterns** — Rewrote Match
  pattern compilation as fully recursive `compile_pattern`.
  Decomposes each pattern into (test_expr, bindings_str); supports
  nesting constructor / tuple / record inside constructor;
  implements `P_int` / `P_str` (strcmp == 0) / `P_bool` / `P_unit`
  / `P_record` (named field destructure) / `P_as` (whole-value
  bind). `is_ptr_ty` / `payload_ty_for_ctor` / `field_ty` helpers
  resolve sub-value types and recursively decompose patterns.
  Verified (clang native): `match 3 with | 0 -> 100 | 1 -> 200 | _
  -> 300` → 300; `match "hello" with | "hi" -> 1 | "hello" -> 2 |
  _ -> 3` → 2; `match Cons (Some 5, Nil) with | Nil -> 0 | Cons
  (None, _) -> 1 | Cons (Some n, _) -> n` → 5 (nested poly
  variant); `match Point { x = 3, y = 4 } with | Point { x = a, y
  = b } -> a + b` → 7. Or-pattern and guard continue to be
  Codegen_error. Added 6 tests + updated 4 substrings to new format
  (755 passing).

- **Phase 4 #13: C codegen polymorphic record monomorphization** —
  Specializes `type 'a Box = { v: 'a }` etc. polymorphic records
  per type (`Box_int`, `Box_str` etc.) using same pattern as
  variant's Phase 4.11. `polymorphic_records` Hashtbl defers
  declarations (emit_record_typedef defers if r_params != []);
  extends `collect_mono_variant_instances` to also cover records;
  `emit_mono_record_typedef` concretizes field types with
  subst_params and generates `typedef struct { int v; } Box_int;`.
  `Record_lit` emit pulls mono name from Record_lit's `.ty` and
  emits compound literal (`((Box_int){.v = 42})`). Field_get and
  Record_update naturally work via `__auto_type`. Verified (clang
  native): `type 'a Box = { v: 'a }; let b = Box { v = 42 } in
  b.v` → 42; `let bi = Box { v = 42 } in let bs = Box { v = "hi"
  } in show (bi.v, bs.v)` → `(42, "hi")` (specializes both Box_int
  and Box_str). Added 3 tests + updated 1 (749 passing; replaced
  "polymorphic record reject" with "specialize verification").

- **Phase 4 #12: C codegen `show` general builtin** — Auto-generates
  per-type specialized `show_T` C functions for `show : 'a -> str`
  by collecting per-call arg types from AST. `collect_show_types`
  finds `App (Var "show", arg)`; `add_with_deps` recursively
  registers types arg type depends on (tuple elem / record field /
  variant payload) (with cycle guard; doesn't infinite-loop on
  self-referential payload of recursive variant). `emit_show_fn`
  generates specialized fn per type — int/bool/str/unit trivial;
  tuple/record composes element show; variant (mono + polymorphic
  instantiation + recursive) is tag dispatch + payload show.
  `emit_expr App`'s `Var "show"` dispatches to `show_<tag>(arg)`
  call resolved by arg type's `ty_tag`. Verified (clang native):
  `show 42` → "42"; `show (1, "hello")` → `(1, "hello")`; `show
  (Some 42)` → "Some 42"; `show [1, 2, 3]` → "Cons (1, Cons (2,
  Cons (3, Nil)))". Based on `asprintf` (malloc leak but consistent
  with other codegen). Added 7 tests (747 passing).

- **Phase 4 #11: C codegen polymorphic variant monomorphization**
  — Implemented monomorphization that collects concrete
  instantiations from AST and fn signatures for `type 'a opt = None
  | Some of 'a` or `type 'a list = Nil | Cons of 'a * 'a list`
  etc. polymorphic variants and emits specialized struct
  (`opt_int`, `list_int` etc.) per instance.
  `polymorphic_variants` Hashtbl defers declarations;
  `mono_variant_instances` accumulates found instances;
  `subst_params` / `subst_variants` for param→arg substitution;
  `mono_variant_is_recursive` for recursion judgment on concrete
  types. Extended `c_type_of` and `ty_tag` to handle `TyCon (n,
  args)` with args (`int list` → `list_int` etc.). `Constr` emit
  pulls mono name from Constr's `.ty`; Match's `is_ptr` judgment
  also recursion-checks with mono name. Verified (clang native):
  `type 'a opt = None | Some of 'a; let v = Some 42 in match v with
  | None -> 0 | Some n -> n` → 42; `type 'a list = Nil | Cons of
  'a * 'a list; let rec sum = fn xs -> match xs with | Nil -> 0 |
  Cons (h, t) -> h + sum t in sum [1, 2, 3]` → 6 (list literal +
  recursive sum; `[1, 2, 3]` is parser-desugared to `Cons (1, Cons
  (2, Cons (3, Nil)))`). Added 4 tests (740 passing).

- **Phase 4 #10: C codegen recursive variant + P_tuple pattern** —
  Switched variants with self-referential payload (e.g. `type ilist
  = INil | ICons of int * ilist`) to heap-allocated node + ptr
  typedef (`typedef struct ilist_node ilist_node; typedef
  ilist_node* ilist; struct ilist_node { ... };`).
  `variant_is_recursive` detects self-reference in payload;
  registers in `recursive_variants` Hashtbl. Constr emit
  malloc-returns ptr with `({ ilist_node* __p = malloc(...);
  __p->tag = N; __p->payload.CTOR = ...; __p; })`. Match emit
  switches `.` vs `->` based on scrutinee's type. Expands P_tuple
  sub-pattern (`CgCons (h, t)`) into `.f0 / .f1` binding sequence.
  Circular typedef dependency resolved by emitting forward decl +
  ptr typedef first, then struct body after tuple/record typedefs.
  Verified (clang native): `type ilist = INil | ICons of int *
  ilist; let rec sum = fn xs -> match xs with | INil -> 0 | ICons
  (h, t) -> h + sum t in sum (ICons (1, ICons (2, ICons (3,
  INil))))` → 6 (linked list sum). Added 5 tests (736 passing).

- **Phase 4 #9 Phase B: C codegen anonymous Fun + closure-with-
  captures** — Lifts anonymous Fun in expression position as
  heap-allocated env struct + adapter + closure construction.
  Capture vars rewritten to `__env_self->name` via
  `current_env_subst` map; capture types resolved by traversing
  scope via `current_var_types` (workaround for polymorphic
  residual problem after let-poly). Closure typedefs emitted in
  inner→outer order (post-order walk) to avoid circular references.
  `current_expected_ty` passes context type to Fun emit;
  estimates inner Fun's type from outer fn's return_ty. Verified
  (clang native): `let apply = fn f -> fn x -> f x in let inc = fn
  n -> n + 1 in apply inc 5` → 6 (curried HOF); `let twice = fn f
  -> fn x -> f (f x) in twice inc 5` → 7; `let make_adder = fn n
  -> fn x -> x + n in (make_adder 5) 10` → 15 (closure with
  capture). Added 4 tests + updated 1 (731 passing).

- **Phase 4 #9 (Phase A): C codegen first-class functions** —
  Represents `T1 -> T2` type function value as C struct
  `closure_T1_T2 = { void* env; T2 (*fn)(void*, T1); }`. Auto-
  generates env-ignoring adapter (`f_closure_fn`) + value const
  (`f_as_value`) for each top-level fn. `c_type_of (TyArrow ...)`
  maps to closure struct name; `ty_tag` also handles nesting.
  `emit_expr Var`: at value position if name is top-level fn, emit
  `f_as_value` (Codegen_error if using inner-lifted in value
  position). `emit_expr App`: known top-level Var call continues
  on direct call fast path; otherwise dispatches via closure
  `({ __auto_type __c = e; __c.fn(__c.env, arg); })`.
  `collect_arrow_types` walks AST + fn signatures to gather arrow
  types and auto-generates closure typedefs. Verified (clang
  native): `let inc = fn x -> x + 1 in let apply = fn f -> f 5 in
  apply inc` → 6 (top-level fn passed as value to HOF works).
  Phase B (inner / anonymous fn value-ization) in separate slice.
  Added 6 tests (727 passing).

- **Phase 4 #8: C codegen closure conversion (defunctionalization)**
  — Added pre-pass that lifts `let h = fn x -> body in ...` inside
  function body to top-level. free_vars helper computes free
  variables (excluding builtin / top-level fn names of typer's
  initial_env); prepends captured variables to C function's param
  list (defunctionalization). `emit_expr` Let sees
  `Hashtbl.mem inner_lifts name` and skips lifted bindings; App
  passes capture args at call site. Captures are int/bool/str/unit
  only (tuple/record/function value capture is Codegen_error).
  Supports multi-level nesting (h captures x and n from 2 levels).
  Side: changed `resolve_fn_types` to pull monomorphic types at
  call site via `find_concrete_arrow` for Fun.ty issue after
  let-poly. Verified: `let outer = fn x -> let h = fn y -> x + y
  in h 10 in outer 5` → 15; nested 2 levels → 6. Added 4 tests +
  updated 1 (721 passing; replaced old "closure reject" test with
  "lift result verification").

- **Phase 4 #7: C codegen variant + match** — Compiles monomorphic
  variant types (`type Status = Ok | Err of str`) to tagged union
  (`typedef struct { int tag; union { const char* Err; } payload;
  } Status;`). `Constr` to compound literal (`((Status){.tag = 1,
  .payload.Err = "boom"})`). `Match` to ternary chain in statement
  expression (`__scrut.tag == N ? ({ binding; body; }) : ...` +
  fallthrough `abort()`). Pattern subset: `P_constr` (nullary or
  `P_var` / `P_wild` sub); `P_var`; `P_wild`. Guard / polymorphic
  variant / nested pattern are Codegen_error. Verified (clang
  native): `type Color = R | G | B; match G with | R -> 0 | G ->
  1 | B -> 2` → 1; `type Status = Ok | Err of str; match Err
  "boom" with | Ok -> 0 | Err msg -> str_len msg` → 4. Added 9
  tests (715 passing).

- **Phase 4 #6: C codegen record support** — Compiles `type Point
  = { x: int, y: int }` to `typedef struct { int x; int y; } Point;`.
  Implements Record_lit / Field_get / Record_update (Record_update
  uses `({ __auto_type __rupd = base; __rupd.f = v; __rupd; })`
  statement expression pattern). `collect_record_names` walks AST
  + fn signature to gather used record types and auto-generate
  typedefs. Extended `compile_to_c` to include top-level decl
  processing (same as Pipeline.type_of, skips eval; only
  record/variant/view/drop registration). Verified (clang native):
  `let p = Point { x = 3, y = 4 } in p.x + p.y` → 7; record update
  → 102; record-returning fn → 15. Polymorphic record (`type 'a
  Box = { v: 'a }`) continues to be Codegen_error. Added 7 tests
  (706 passing).

- **Phase 4 #5: C codegen tuple support + AST type annotation
  foundation** — As foundation, added `mutable ty : ty option` to
  `Ast.expr`; `Typer.infer` now records inference results on each
  node. This lets codegen directly reference per-node types.
  Compiles `Tuple` to C struct (`typedef struct { ... }
  tuple_int_int;`) + C99 compound literal `((tuple_int_int){.f0 =
  1, .f1 = 2})`. Compiles `fst` / `snd` builtin to `.f0` / `.f1`
  field access. Supports arbitrary element types (int/bool/str +
  nested tuple); auto-generates struct per shape
  (`collect_tuple_shapes` walks entire AST + fn signature).
  Verified (clang native): `let p = (1, 2) in fst p + snd p` → 3;
  `let p = ("hello", 42) in print (fst p)` → "hello"; `let split
  = fn s -> (s, str_len s) in print (fst (split "hello"))` →
  "hello". Added 6 tests (699 passing).

- **Phase 4 #4: C codegen: str-taking / returning functions** —
  Allows lifted function param / return to also use str (const
  char*). Added `param_ty` / `return_ty` to `fn_decl`;
  `lift_fn_skels` extracts skeletons → `resolve_fn_types` flows
  all lifted fns to typer as one let-rec group for type inference
  (handles self / mutual recursion) → `c_type_of` maps Ast.ty to
  C type (int/bool → `int`, str → `const char*`, unit → `int`).
  Compiles `str_len` builtin to C's `strlen` (App special case).
  Verified (clang native): `let greet = fn n -> if n > 0 then
  "pos" else "neg" in print (greet 5)` → "positive"; `let exclaim
  = fn s -> s ++ "!" in print (exclaim "hello")` → "hello!";
  `str_len "hello, world!"` → 13. Added 5 tests (693 passing).

- **Phase 4 #3: C codegen string support** — Compiles `Str_lit`
  to C string literal; `++` via runtime helper `__lang_str_concat`
  (malloc-based); `print` builtin to `puts` (statement expression
  returning int 0). Switched `let` to GNU/Clang extension
  `__auto_type` so same emit works for both int/str values. Made
  `emit_program` type-aware (`~main_ty`); selects printf's format
  from main's type (int/bool → `%d`, str → `%s`, unit → printf
  skip). Verified: `print "hello, world!"` → hello, world!;
  `"hello" ++ " " ++ "world"` → hello world (all clang native).
  Malloc leaks (region/GC integration in future slice). Added 6
  tests / restructured existing codegen tests as fragment
  inspection (688 passing).

- **Phase 4 #2: C codegen function lifting** — Lifts top-level
  `let f = fn x -> ...` and `let rec f = fn x -> ... and g = fn
  y -> ...` as C function (with forward declaration). Compiles
  `App (Var name, arg)` form direct calls to C `name(arg)`; both
  self-recursion and mutual recursion work (factorial 10 =
  3628800, fibonacci 15 = 610, is_even 7 = 0 confirmed via clang
  native). Closure (`fn ...` inside function body) continues to be
  Codegen_error. Added 5 tests (681 passing).

- **Phase 4 #1: C codegen MVP** — First step from interpreter to
  native. Implemented `emit_program : Ast.program -> string` in
  new `lib/codegen_c.ml`; converts subset of int / bool / arith /
  cmp / logic / Neg / If / Let (P_var only) / Var / Annot to C
  expression (let compiled to single C expression via GCC/Clang
  statement expression `({ ... })`). Added `-c FILE` / `-ce
  <expr>` flags to CLI; outputs C source to stdout. `clang OUT.c
  -o BIN && ./BIN` for native execution. Functions / strings /
  record / variant / region / view etc. now Codegen_error. Added
  7 tests (677 passing); manual E2E verified via `clang` (`let a
  = 10 in let b = 20 in if a + b > 25 then a * b else 0` → 200).

- **example: examples/pipeline.mere** — Realistic example
  (~75 lines) combining region / view / effect (builtin Logger /
  Metrics + cap passing + using sugar) / with Drop. Simple build
  pipeline: open/close user session with `with session =
  open_session logger uid`; process each task with `region R {
  ... }`; inside region build `view Task[R]` to calculate size.
  Output is session open/close log + per-task [task] log +
  [METRIC] inc / record + user log + final total. Demonstrates
  Mere's full feature set working consistently in a practical
  example.

- **Phase 3.1: `with` Drop semantics** — `with c = v in body`
  requires v's type to be a Drop type (declared `drop type ...`);
  Trivial value is type error (use `let`). On eval side, calls v's
  `close: unit -> unit` field at scope end (no-op if absent).
  Multiple `with x, y in body` close in LIFO order y → x. Rewrote
  examples/with_caps.mere based on Drop type. Implemented case (i)
  of design doc 12_drop_and_with.md. Added 6 tests / restructured
  6 (670 passing).

- **effect: builtin `Logger` / `Metrics` cap types + `mk_logger`
  / `mk_metrics` constructor builtins** — Provides cap types as
  stdlib. Registered `Logger { info, warn, error: str -> unit }`
  and `Metrics { inc: str -> unit, record: str -> int -> unit }`
  in typer; added corresponding V_record constructor functions to
  eval. Users don't need to redefine cap types each time
  (overrides allowed). Rewrote examples/effects.mere with builtin
  usage. Added 7 tests (668 passing).

- **effect: `using [cap]` syntax sugar** — Desugars `fn x using
  [logger] -> body` to `fn logger -> fn x -> body` (caps are
  outer-most curried args). Eases partial application iteration
  frequent in cap-passing style (main pattern of Q-003/Q-006
  solution). Type annotations allowed; multiple caps allowed;
  combination with regular params allowed. Implements auxiliary
  design of design doc `10_effect_trial_findings.md`. Added 7
  tests (661 passing). Rewrote examples/effects.mere in sugar
  form too.

- **example: examples/effects.mere** — Demonstration of
  Capability passing pattern (about 75 lines). Declares `Logger`
  / `Metrics` cap types as records; demos 3 patterns: direct use
  in low-order function / bucket-brigade / partial application
  passing to high-order function. Demonstrates that design doc
  `05_effect_system.md`'s "side effects = passing capability as
  values" works with current Mere (HM + function args + record
  + curry) alone — no need for new syntax for effect system.

- **region Phase 2.6**: `Trivial[R]` constraint — Allows declaring
  Drop type with `drop type Name = ...`. At `&R v` / `R.alloc(v)`
  / view field construction, walks inner type; if it includes a
  type registered in `drop_types` registry, type error "Trivial[R]
  violated". Function type is Trivial (closure value itself is not
  Drop). Syntactified case (i) of design doc 12_drop_and_with.md.
  `with` expression + Drop execution in Phase 3. Added 7 tests
  (654 passing).

- **region Phase 2.5**: `R.alloc(v)` syntactic sugar — Method-call
  style notation for `&R v`. Parser holds region_stack; inside
  `region NAME { ... }` body, desugars `NAME.alloc(EXPR)` to `Ref
  (NAME, EXPR)`. If R is not an in-scope region, treats as
  regular field access; existing `obj.alloc(...)` patterns
  unaffected. Added 7 tests (647 passing).

- **region Phase 2.4**: type-level region tag for view values +
  region propagation for field access / record update — View
  construction returns `TyCon (name, [TyRef (target_region,
  TyUnit)])` to embed region in value type; `Field_get` /
  `Record_update` reads view name + embedded region and uses
  `subst_region` to substitute field type with actual region.
  View value itself becomes target of escape check (`Cell[S]`
  can't be carried out of region S). Added `Name[R]` notation
  heuristic to pp_ty. Added 5 tests (640 passing). Resolves
  known limitation "field access returns raw R" from Phase 2.3.

## 2026-06-16

- **region Phase 2.3**: enforces region of view construction +
  region parameter substitution — View can be constructed only
  inside `region { ... }` block. At construction, view
  declaration's region parameter `R` is substituted with active
  region name; if field has `&R T`, tag aligns automatically even
  with different region name. Added views Hashtbl and
  active_regions stack to typer; push/pop at `Region_block`; view
  dispatch + `subst_region` at `Record_lit`. Ties in with §5
  "view type" section of memory-model.md.

- **region Phase 2.2**: `view V[R] of T { fields };` declaration —
  Introduced view type fixed in Q-009 as syntax. Like `view
  Node[R] of int { value: int, next: int };`, takes region
  parameter `[R]` and (optional) internal type `of T`, declares
  fields with `{ field: ty, ... }`. In Phase 2.2 treated as
  "region-tagged record" (region is only recorded, not enforced);
  `Node { value = 1, next = 0 }` construction and `n.value` access
  work. Strict semantics (construction only inside region;
  mandatory `&R T` fields) in future Phase. Design doc:
  `14_view_types.md`'s 3 axioms (immutable / region-scoped /
  structural identity) at stage of syntactifying first 2.

- **region Phase 2.1**: `&R v` value expression + escape check —
  `&R 5` turns value into region-tagged reference type. At exit
  of `region R { body }`, checks if body's type leaks R; compile-
  time error if leaked. Region promoted from "type-system label"
  to "actual safety guarantee".

- **region / `&R T` Phase 1** — First step into memory model.
  `region R { body }` expression introduces R as region name into
  scope; added `&R T` as reference type to AST/typer/eval. Phase
  1 is **syntax only** — escape check, Trivial constraint, view
  type, `r.alloc(v)` semantics from Phase 2 onward. Design doc:
  corresponds to 11_region_vs_arena.md / 14_view_types.md.

- **Exhaustiveness Phase 1** (Exhaustive module) — Detects bool
  and variant type exhaustiveness as warnings. `match Some x with
  | Some n -> ...` outputs "missing None" to stderr but evaluation
  continues. Guarded arm conservatively "not covered"; as-pattern
  and or-pattern transparent. lib/exhaustive.ml doesn't depend on
  Typer (Typer calls register_variants to populate).

- **Math builtins 8** (`pi`/`e` constants + `sqrt`/`f_abs`/`f_neg`/
  `floor`/`ceil`/`round`) — Float arithmetic basics complete.

- **`int_max`/`int_min` constant builtins** — Mere's first
  non-function builtins.

- **`time : unit -> float` + `exit : int -> 'a`** — Unix epoch
  and process termination.

- **Float comparison 4** (`f_lt`/`f_le`/`f_gt`/`f_ge`).

- **CSV parser example** (~130 lines, reduced RFC 4180).

- **mini_calc.mere extension**: let binding + variables + env-
  based eval; shadowing works.

- **list_lib.mere** added: 12 list utility functions written in
  Mere itself (map/filter/fold_left/fold_right/length/rev/take/
  drop/range/replicate/for_all/any).

- **Float type introduced** — `TyFloat` primitive + `Float_lit`
  (`1.5` literal) + V_float; 4 conversions (`float_of_int` /
  `int_of_float` / `str_of_float` / `float_of_str`) + 4 arithmetic
  (`f_add` / `f_sub` / `f_mul` / `f_div`). No implicit int/float
  conversion. Resolves known limitation "no float".

- **File I/O** — `read_file : str -> str` / `write_file : str ->
  str -> unit`. Can write CLI tools. Added `examples/word_count
  .mere`.

- **`str_unescape` builtin** — Decodes `\n` `\t` `\r` `\\` `\"`
  `\/`. Escape-string support for JSON parser.

- **Character literal `'X'`** — Lexer only; length 1 str.
  Disambiguates with tyvar `'a` (closing quote presence); `match
  c with | 'n' -> ...` for dispatch.

- **List display improvement** — `to_string` displays Cons/Nil
  chain as `[a, b, c]`. JSON parser output dramatically more
  readable.

- **Documentation overhaul** — README rewrite + newly added
  `docs/{tutorial, language-reference, stdlib-reference,
  patterns}.md` (1100+ lines).

- **`divmod`** — Mere's first tuple-return builtin (`int → int →
  (int * int)`).

- **`square` / `cube`** — int → int 2nd / 3rd power.

- **`sum_range`** — O(1) sum via Gauss formula.

- **`incr` / `decr`** — int → int +1 / -1.

- **`iter_n`** — Higher-order side-effect loop.

- **Polymorphic `const` / `flip`** — Mere's first 3-quantified,
  higher-order polymorphic builtins. Implemented via forward-ref
  of `apply_value_ref`.

- **Polymorphic `id` / `swap` / `pair`** — Standard set of tuple
  ops complete.

- **Polymorphic `fst` / `snd`** — Mere's first 2-quantified
  scheme builtins.

- **`try_or`** — Mere's first error-handling builtin.

- **`fail` / `show`** — Mere's first polymorphic builtins
  (scheme.quantified).

- **as-pattern / or-pattern** — `(a, b) as p`, `| 1 | 2 | 3 ->
  ...` (typer enforces binding name/type match).

- **Structural equality** — `==` / `!=` recursively compare
  tuples / records / constructors.

- **Type alias `type Name = T;`** — Parse-time substitution;
  disambiguates variant/record/alias via `|`/`of`.

- **Function composition `<<` / `>>`** — Right-associative;
  higher precedence than `|>`.

- **Multiple type parameters `('a, 'b) result`** — Resolves known
  limitation "up to 1 type parameter".

- **Top-level let pattern** — `let _ = ...;`, `let (a, b) = ...;`
  etc. at top-level; resolves known limitation.

- **If without else** — `if cond then body` (body unit type).

- **Match guard `| pat when expr -> body`** — Resolves known
  limitation "no guard".

- **Block expression `{ e1; e2; eN }`** — Parser sugar for
  Let(P_wild) chain.

- **List pattern `[a, b, ...t]`** — Symmetric to literal; parser
  sugar.

- **Record update `{ p | x = 10 }`** — Immutable update.

- **Record type `type Point = { x: int, y: int }`** — Nominal
  records; polymorphic; partial pattern.

- **Mutual recursion `let rec ... and ...`** — Resolves known
  limitation "no mutual recursion".

- **List literal `[1, 2, 3]`** — Parser sugar for Cons/Nil chain.

- **Pipe `|>` / signature alias** — Ergonomic improvements.

- **Multi-arg typed fn** — `fn (x: int, y: str) -> body` desugars
  to curry.

- **Massive stdlib additions** — print_int / str_of_int /
  int_of_str / str_len / not / min / max / abs / pow / gcd / lcm
  / clamp / sign / even / odd / chr / ord / to_upper / to_lower
  / str_trim / str_rev / str_contains / str_count / str_replace
  / str_starts_with / str_ends_with / str_repeat / substring /
  char_at / is_digit / is_alpha / is_space / read_line /
  print_no_nl / print_err / assert / bool_of_str / str_compare
  and many more.

---

## 2026-06-15 — 06-16 (early week)

- Main extensions: operator expansion (`/ %` `<= >= > !=` `&& ||`),
  let pattern, `with` expression, polymorphic types (`'a opt`),
  tuples, sum types + pattern matching.
- Design docs: Q-008 (region/arena integration), Q-009 (view type
  3 axioms), Q-010 (region-version std), Q-011 (Drop order).
  Mere's memory model design map complete.

---

## 2026-06-06 (start date)

- After OCaml 4-phase trial, fixed host language as OCaml (Q-001
  resolved).
- In 1 day, completed minimum core "integer + let + bool + if +
  function + recursion + bidirectional type check + REPL" (24
  tests).
- Strings + print + `++` concat + unit (slice 1); REPL (slice 2);
  multiple top-level decls (slice 8).
- **Hindley-Milner type inference + let-polymorphism**: implemented
  Algorithm W + occurs check + generalize/instantiate. Inference
  of annotation-less functions, polymorphic id, polymorphic
  compose, let-poly all work (slice 9, 29 tests).

---

## Cumulative (as of 2026-06-16)

- Design docs: 4 (Q-008/009/010/011)
- Implementation slices: **62**
- Tests: **567** (initial 35 → 567, 16×)
- Builtins: **68**
- Known limitations resolved: **8** (mutual recursion / guard /
  multi-type-param / top-level let pattern / list display / char
  literal / file I/O / float)

---

## Not yet started (future)

- **`&T` reference** — borrow annotation (`&shared write` etc.)
  → core of memory model
- **`region R { ... }` / `view V[R] of T`** — implementation of
  Q-008/009
- **Effect system** — capability types and effect tracking
- **Native codegen** — LLVM or Wasm
- **Exhaustiveness check Phase 2** — precise exhaustiveness for
  int/str/float/tuple/record; redundancy check
- **Inline unicode / Unicode source** — currently ASCII only
- **Module system** — file split + namespace
- **Dependent types / refinement types** — staged introduction
  per 04_fundamental_tradeoffs.md
- **Row polymorphism** — no annotation needed for record update
- **Multi-line REPL** — REPL is single-line only

