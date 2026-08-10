# Reserved names — Mere top-level fn names and C codegen collisions

Mere's C codegen **emits top-level fns directly as C functions**. As a result, if a top-level `let` / `let rec` binding name **collides with an existing function in libc / libm on macOS / Linux** or with a **C language keyword**, codegen succeeds but `clang` / `gcc` then fail with a **compile error**.

The interp / LLVM / Wasm backends are unaffected (so a program that runs in interp can fail in C codegen). Because this is easy to miss, the **Phase 38.A3 linter** issues a warning at parse time. This document is the full list of reserved names plus avoidance patterns.

> **TL;DR**: writing a top-level binding that collides with any name in the table below produces a warning + C compile error at codegen time. Avoid it via a **prefix (`m_` / `mere_`) / suffix (`_` / `_v`) / verb phrase (`run_*` / `*_list`)**.

## 1. Collision list (~110 names)

The implementation is in [`lib/pipeline.ml:42`](../lib/pipeline.ml) under `reserved_c_names`. Defining a top-level binding with one of these names triggers a Phase 38.A3 linter warning.

### 1.1 C keywords (~30)

`short` / `long` / `int` / `char` / `float` / `double` / `signed` / `unsigned` / `register` / `static` / `auto` / `extern` / `const` / `volatile` / `restrict` / `inline` / `goto` / `return` / `break` / `continue` / `switch` / `case` / `default` / `do` / `while` / `for` / `if` / `else` / `sizeof` / `typedef` / `struct` / `union` / `enum` / `void`

Most likely to hit: **`case`** (often when writing match-arm helpers), and **`default`** / **`type`** / **`return`** (common in DSL-style naming).

### 1.2 stdlib.h (libc, ~22)

`div` / `ldiv` / `exit` / `abort` / `atexit` / `atof` / `atoi` / `atol` / `free` / `malloc` / `calloc` / `realloc` / `system` / `getenv` / `setenv` / `putenv` / `unsetenv` / `rand` / `srand` / `abs` / `labs` / `qsort` / `bsearch` / `mergesort`

Most likely to hit: **`div`** (rationals / matrices / GCD-style code), **`rand`** (random helpers), **`abs`** (people often shadow the builtin absolute-value function).

### 1.3 math.h (libm, ~17)

`pow` / `sqrt` / `sin` / `cos` / `tan` / `asin` / `acos` / `atan` / `atan2` / `exp` / `log` / `log10` / `log2` / `ceil` / `floor` / `round` / `trunc` / `fabs` / `fmod` / `hypot` / `sinh` / `cosh` / `tanh`

These are also defined as Mere builtins with the same names (e.g. `pow` / `sqrt`). **A same-named user top-level binding shadows and collides**. Avoid with `mere_pow` / `power_int` etc.

### 1.4 time.h (libc, ~9)

`time` / `clock` / `ctime` / `asctime` / `gmtime` / `localtime` / `mktime` / `difftime` / `strftime`

Most likely to hit: **`time`** (shadowing the builtin time-fetching function).

### 1.5 POSIX I/O (~18)

`read` / `write` / `open` / `close` / `lseek` / `stat` / `fstat` / `fopen` / `fclose` / `fread` / `fwrite` / `fseek` / `ftell` / `rewind` / `printf` / `scanf` / `fprintf` / `fscanf` / `sprintf` / `sscanf` / `puts` / `gets` / `fputs` / `fgets` / `putchar` / `getchar`

Most likely to hit: **`read`** / **`write`** (when writing file-I/O wrappers); **`printf`** (debug helpers).

### 1.6 misc libc (~15)

`strlen` / `strcpy` / `strncpy` / `strcat` / `strncat` / `strcmp` / `strncmp` / `strchr` / `strrchr` / `strstr` / `strdup` / `strerror` / `memcpy` / `memmove` / `memset` / `memcmp` / `memchr` / **`main`**

`main` is especially important — C reserves it as the execution entry point. A Mere top-level expression automatically becomes the `main` function, so a user `let main = ...` is **always a conflict**.

## 2. Avoidance patterns (3)

| Pattern | Example (collision name → safe name) | Use case |
|---|---|---|
| **Suffix** | `case` → `case_` / `case_v` / `run_case` | One-character addition suffices. `case_v` is the example the linter message suggests (no deep meaning) |
| **Prefix** | `div` → `divi` / `mere_div`; `pow` → `power_int` / `m_pow` | Carries a namespacing nuance; the `mere_` prefix is recommended for contrib libs |
| **Verb phrase** | `mergesort` → `sort_list`; `pow` → `power_of` | The most natural-language-readable; recommended for lib APIs |

**Recommended approach**:
- **Personal helpers / one-off fns**: suffix (`case_` / `_v`)
- **Public lib fns (contrib)**: verb phrase (`run_case` / `power_of`)
- **Internal fns of a module-ified lib**: prefix (`m_div`) to suggest the module's family

## 3. A different axis: shadowing a *builtin*

The list above is about names the **C compiler** already owns. A separate
hazard is a name **Mere** already owns: a top-level `let join = ...` is a
perfectly good C identifier, but `join` is also the thread builtin, and a
backend that lowers `join x` to `pthread_join` without first asking whether
the user bound that name miscompiles the program.

The rule is that a user binding — local, lifted inner fn, or top-level —
**wins** over a same-named builtin, from its declaration onward.

Until v0.1.172 each backend enforced that with a private guard on individual
builtins, added one incident at a time: C had 39 of 95 dispatch arms guarded,
Wasm 14 of 139, LLVM 6 of 70. The rest were silent — `let str_len = fn (s:
str) -> 999` returned 999 on the interpreter and 5 on all three compiled
backends, with no error and no warning. Each backend now asks the question
once, before any builtin arm can match: if the head of an application spine
is a name the program bound, the call goes to the ordinary call paths and
never meets the builtin arms at all.

**Declaration order matters**, because top-level bindings are sequential —
the typer rejects a forward reference. A builtin used *above* a later
same-named binding is still the builtin:

```mere
let show_of = fn (n: int) -> "SHOWN " ++ show n;   // the builtin show
let show = fn (n: int) -> "MY SHOW";               // from here on, yours
```

`test/parity/shadow_builtin.mere` and `test/parity/toplevel_shadows_builtin.mere`
lock all of this down across the four backends the parity harness runs:
top-level, local and lifted-inner bindings, one- and three-argument calls,
use in value position, and the ordering rule above.

Unlike a C collision, this is **not** linted, because there is nothing wrong
with the program: shadowing is legal and the intent is unambiguous. It is the
backend's job to honour it.

Names most likely to collide this way: **`join`** (string-join helper),
**`run`** (any interpreter or driver loop), **`args`**, **`show`**,
**`time`**.

## 4. See also

- **Linter implementation**: [`lib/pipeline.ml:42-82`](../lib/pipeline.ml) (Phase 38.A3)
- **patterns.md §5**: condensed version of this doc
- **language-reference.md**: Mere language reserved words (`let` / `fn` / `match` / `if` etc.) are separate — they're rejected by the parser and can't be used as binding names.

## 5. Future extensions (DEFERRED)

| Stage | Content |
|---|---|
| A. Auto-rename suggestions | The linter would suggest name-specific replacements like "`pow` → `power`" or "`case` → `case_`" (currently only generic `_` / `m_` / `_v` are suggested) |
| B. Namespacing | Allow same-named top-level bindings inside modules (currently `M.case` after module rewrite is still emitted as a C function, so it's blocked) |

Both are issue-driven work for after public release.
