# Reserved names — Mere's reserved words, and the C collisions that are left

Two different things make a name unusable, and they fail in different places:

- **Mere's own reserved words** (§0) are refused by the parser, on every backend,
  with the word named.
- **C collisions** (§1) are names the C compiler already owns. Since v0.1.538 this
  applies to **type names only**: a top-level `let` / `let rec` name is emitted with
  a prefix by every backend (`mu_div` on C), so `let div = ...`, `let malloc = ...`,
  `let printf = ...` and `let case = ...` compile and run on all five. A **type**
  name is not prefixed on the C backend -- `type wait = ...` lowers to
  `typedef struct wait wait;` and collides with `union wait` in `<sys/wait.h>` -- and
  that is what the linter still warns about.

> **TL;DR**: a reserved word (§0) cannot be a name at all. A `type` whose name is in
> §1 compiles on the interpreter, LLVM and Wasm and fails in the C compiler; rename
> it with a prefix (`m_`) or suffix (`_`).

## 0. Mere's reserved words (33)

`let` / `rec` / `and` / `in` / `if` / `then` / `else` / `for` / `do` / `while` /
`true` / `false` / `fn` / `type` / `signature` / `region` / `view` / `drop` /
`using` / `module` / `import` / `open` / `extern` / `trait` / `impl` / `dyn` /
`derive` / `match` / `with` / `when` / `of` / `as` / `_`

The list is the lexer's table (`Lexer.keywords`), and `scripts/keywords_doc_check.sh`
fails when a word there is missing here or from language-reference.md -- which is
how `view` went unlisted from the day it was added until v0.1.538. A reserved word
used as a name is refused with the word named:

```
let view = 5;   // error: `view` is a reserved word, so it cannot be a name here
```

Most likely to hit: **`view`** (UI code), **`type`**, **`match`**, **`open`**,
**`module`**, **`drop`**. `pub` is **not** reserved (see language-reference.md).

## 1. C collisions — type names (~110 names + struct tags)

The implementation is in [`lib/pipeline.ml`](../lib/pipeline.ml) under
`reserved_c_names` and `reserved_c_type_names`. Declaring a `type` with one of these
names triggers a warning, because the C backend emits it as a C typedef under the
same name.

⚠ **Until v0.1.538 the same warning fired for top-level `let` names too**, saying
"this will be a compile error at codegen". That had stopped being true: every
backend prefixes top-level bindings, and a program binding `div`, `malloc`,
`printf`, `memcpy`, `strlen`, `case` and `main` printed the same answer on the
interpreter, C, LLVM, Wasm and RV32. The warning was a false alarm on every
backend, and it was removed rather than reworded.

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

## 2. Avoidance patterns (3) — for a type name in §1

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

§1 is about names the **C compiler** already owns. A separate
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

- **Linter implementation**: `warn_reserved_type_name` in [`lib/pipeline.ml`](../lib/pipeline.ml) (Phase 38.A3; type names only since v0.1.538)
- **patterns.md §5**: condensed version of §1
- **language-reference.md**, "Keywords": the same reserved words as §0, held to the lexer by the same gate.

## 5. Future extensions (DEFERRED)

| Stage | Content |
|---|---|
| A. Auto-rename suggestions | The linter would suggest name-specific replacements like "`pow` → `power`" or "`case` → `case_`" (currently only generic `_` / `m_` / `_v` are suggested) |
| B. Prefix type names on the C backend | The fix that would retire §1 entirely: a `type` would lower to a prefixed typedef the way a `let` lowers to a prefixed function |

Both are issue-driven work for after public release.
