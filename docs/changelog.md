# Changelog (mere)

Major implementation milestones recorded per-slice (newest first). See `git log` for detailed commit messages.

---

## v0.1.303 — 2026-08-22

_A repeated JSON key was resolved by accident, in three different ways._

`of_json` accepted `{"id":1,"id":2}` on every backend that decodes JSON and kept
the FIRST value. Nobody decided that. It fell out of building an association list
in document order and looking it up front-to-back — and Go's `encoding/json` v1
kept the LAST for an equally accidental reason, which is the whole argument:
two implementations resolve the same bytes to different values, so there is no
right one to pick. Go 1.27's `encoding/json/v2` stopped picking, and this does
too. `of_json` fails; `of_json_opt` answers `None`.

The check went into the three PARSERS, one per backend — the interpreter's
`parse_object`, the C runtime's `__mj_obj`, the Wasm runtime's `$__mj_object` —
not into the per-type decoders generated from a record's fields. That is why a
duplicate nested three levels down is refused too, and why the rule did not have
to be written once per type. (`lib/json.ml` is untouched: it parses the language
server's wire format, not user data, and holds no `of_json` traffic.)

`test/parity/json_duplicate_key.mere` CHECKS THE ACCEPTING CASES FIRST. A change
that rejected everything would have passed a file that only ever asked whether
rejection happens, so the clean object, the reordered one and the whitespace-
heavy one come before the seven duplicates. It also asks both orderings — the
duplicate early and the duplicate late — because a decoder keeping the last
would have agreed with one and not the other.

The comparison is on `of_json_opt` returning `None`, not on a message. The three
backends do not word a decode failure the same way: the interpreter appends
`(at offset N)`, the C runtime does not, and the Wasm runtime has no message
channel at all, only a flag. Comparing messages would have pinned that unrelated
difference instead of this behaviour.

Still accepted: invalid UTF-8 inside a string. Go 1.27 rejects both, but that
half needs a validator that does not exist here yet, and it has to be reconciled
with `utf8_len` counting an invalid byte as one unit on purpose.

---

## v0.1.302 — 2026-08-22

_Two dogfoods had already written this search, and both wrote it the slow way._

`str_index_of` searched from the front and there was no counterpart from the
back, so callers that needed the LAST occurrence wrote their own. Two did:
`contrib/url` (userinfo ends at the last `@`, because a password may contain
one; the port follows the last `:`; a path's final segment starts after the
last `/`) and `contrib/path` (`basename` / `dirname` / `ext`). A third copy sat
in `contrib/url/ipv6.mere` for the last colon of an embedded IPv4 quad. Each
carried a comment saying the builtin did not exist -- which is the useful part
of the record: the workaround was written down as a workaround rather than
quietly becoming the way it is done.

Every copy scanned with `char_at`, and `char_at` returns a one-character `str`.
On the compiled backends that is an allocation per byte examined, so finding one
index in an n-byte string allocated n strings. `str_last_index_of` is a memcmp
scan in all four backends and allocates none.

The empty needle answers the haystack LENGTH, not 0. It occurs at every position
including one past the final byte, and this function reports the last of them --
which keeps `str_index_of s "" <= str_last_index_of s ""` true for every `s`.

Both lengths come from the length header (`__lang_str_size` in C, the same in
the LLVM transcription, `__lang_strlen` in Wasm), never from `strlen`: a `str`
has been able to hold NUL since v0.1.264, and `test/parity/str_last_index_of.mere`
searches a haystack containing two of them for exactly that reason.

Also: `test/parity/path_helpers.mere` is new. `contrib/path` had no test of its
own -- its only caller is the docs-site build -- so the three functions rewritten
here had nothing holding them. Before deleting the hand-written versions they
were run against the builtin over a corpus of paths and separators and agreed on
every pair.

Not on RV32I: that backend does not have `str_index_of` either, and the pair
stays symmetric.

Adding it took SIX registrations, not four. Besides the typer and the four
backends, `contrib/typer/typer.mere` carries its own builtin type environment and
`contrib/codegen/codegen_wasm.mere` its own known-builtin predicate, dispatch,
WAT helper and helper-name table -- and the self-host tests compile
`contrib/path/path.mere`, so the moment that file used the new builtin the
bootstrap failed with `unbound var str_last_index_of`. Twice, once per layer. A
builtin is not added until all six agree it exists.

### The parity gate can now hold a program that blocks

`scripts/parity.sh` ran every program with no time limit, so a case that blocked
forever would have hung the gate rather than failed it -- nothing reported, no
log, and every case after it unknown. All eight execution sites (the interpreter
reference and the three compiled runs, in both the ordinary and the
supposed-to-fail loop) now go through a perl `alarm` wrapper, and outliving the
limit is its own outcome, `HUNG`, named in the summary rather than folded into a
DIFF. `timeout(1)` is absent on macOS and `ulimit -t` measures CPU time, which a
thread blocked on a condition variable does not spend; neither would have worked.
The limit is generous (60s, `MERE_PARITY_TIMEOUT`) because it exists to convert a
hang into a report, not to time anything.

That was the prerequisite for the first concurrency cases this suite has ever
had. There were 128 parity programs and not one of them spawned a thread, while
the concurrency checks in `test_basic.ml` name `(interp)` in their own titles --
so "the interpreter and the C backend agree about threads" was not a claim
anything held. Three cases now hold it: `concurrency_channel` (spawn / send /
recv / join / close / recv_opt, with every output made order-independent by
construction), `concurrency_elem_types` (what a channel can carry -- int, str,
a str containing NUL, bool, a record -- which turns out to MATCH on all four
backends, not just the two that have the full channel API), and
`channel_unconstrained_elem`, a regression case for the v0.1.293 copier fault
reached through a channel instead of a trait, which is the entrance that fix
did not gate.

---

## v0.1.301 — 2026-08-24

_A fail now releases the regions it jumps over._

Since v0.1.31, a `fail` that longjmps out of nested `region R { }` blocks
restored the current-region pointer and let the abandoned blocks' chains
leak -- noted at the time as acceptable, because regions were rare and
failures rarer. Both stopped being true: an interpreter that wraps every
method call in a region and models every guest exception as a `fail`
leaks about a megabyte per caught failure (measured: 2,000 rescued fails
= 2.1 GB peak; flat at 4 MB once released).

The C backend now keeps a thread-local ACTIVE-REGION STACK: block acquire
pushes, block release drops (searching from the top, because the
`region R loop` swap releases the arena under the one it just pushed), and
`try_or`'s catch arm unwinds the stack to the depth saved at entry --
releasing every chain the longjmp skipped -- before restoring the current
region. Nested try_or nests the saved depths. Thread exit frees the
stack's storage along with the cached block regions.

The interpreter is unaffected (OCaml exceptions unwind, the GC owns
memory). The LLVM and wasm backends keep their previous behavior --
same values, backend-specific footprint; they get the same treatment
when something that runs on them does fail-heavy region work. New parity
lock: `region_fail_unwind` (fail through nested regions, nested try_or,
fail out of a region loop -- every backend answers the same bytes).

## v0.1.300 — 2026-08-23

_The frame-pool primitive._

`map_recycle m`: semantically `map_clear`, and on the C backend it also winds
the map's private arena back to its warm seed block, freeing only the growth
-- so a map reused as a CALL FRAME recycles at every return and the next use
mallocs nothing. Promotes an unowned map on first use. The consumer this was
built for holds a pool of frame maps: take one at call entry, recycle and
return it at call exit unless the frame was captured (a proc, a binding, a
define_method body) -- which is how an interpreter's per-call frames, its
single largest unreclaimed share, come back without the env-indirection
surgery that a store-based frame representation would have cost (measured at
a 518-function transitive closure).

Borrowed internals dangle across a recycle, same discipline as map_compact.
The interpreter and wasm lower it to map_clear exactly, so parity holds by
construction.

parity 121/0 (the compact probe exercises recycle-reuse-recycle on all
three), dune test 2541/0.

---

## v0.1.299 — 2026-08-22

_A trigger cannot see byte pressure through an entry count._

`map_bytes m` / `vec_bytes v`: the bytes held by the container's OWN arena --
0 until the first compact promotes it, capacity rather than bump-used (within
2x, costs nothing on the hot path, monotone between compactions: everything a
collection trigger needs and nothing more). Found the way most of this week's
primitives were found, by a consumer: a store of 20 KB values under-collected
on any count-based trigger, and a large program's collector STARVED outright
-- its amortization term grew with total-slots-ever while its trigger counted
entries, so collections effectively stopped and an 87 GB peak looked like "GC
present, memory anyway".

The value is deliberately backend-dependent (0 where no per-container arenas
exist: interpreter, wasm) -- so it is for TRIGGERS, never for output. The
parity probe uses it only in output-invariant positions, which is the rule
for any program that wants to stay portable.

Blocks carry their capacity in the header's padding field now, which is what
lets bytes be summed without a hot-path counter.

parity 121/0, dune test 2541/0, ctest.

---

## v0.1.298 — 2026-08-22

_Emptying a map one key at a time was quadratic, and worse in a private arena._

`map_clear m`: length to zero, index wiped, O(index) and allocation-free. The
missing mass-deletion primitive: `map_delete` keeps the dense arrays shifted
and REBUILDS the hash index into the map's region on every call, so deleting
half of a big map key by key is quadratic time and linear-times-index-size
ALLOCATION. Found by v0.1.297's first consumer: a collector that deleted a
store's dead entries one by one watched the store's freshly-promoted private
arena double its way to 68 GB -- every delete allocating a new index into the
very arena the compaction was about to reclaim. The pattern that replaces it:
collect the survivors, `map_clear`, re-set, `map_compact`.

All backends answer the same bytes: interp (Hashtbl.reset), C (len = 0, index
wiped), wasm (len = 0, in both the linear and the hash map runtimes -- the
first patch landed in a third, LEGACY runtime that is emitted for nobody, and
the parity gate said MISCOMPILE before the push instead of after).

parity 121/0 (the compact probe now exercises clear on all three), dune test
2541/0, ctest, selfhost_check.

---

## v0.1.297 — 2026-08-22

_A container can hand back its own dead bytes._

`map_compact m` / `vec_compact v`: semantically invisible -- same entries,
same order, same handle -- and allocator-visible. On the C backend the
container's internal storage (arrays and every owned copy) moves into a fresh
private arena and the previous generation is freed, so overwritten values,
deleted entries' copies and abandoned grown arrays actually return to the OS.
The first call PROMOTES the container to owning its arena; containers never
compacted never pay (a per-call frame map costs nothing new -- promotion is
lazy precisely because an interpreter makes millions of maps and compacts
five). The interpreter and Wasm answer with a no-op, which is correct:
compaction is an optimization, not an observable, so parity holds trivially.

Why a primitive and not a library: the alternative was measured first. Moving
a program's stores into a region-loop carry works when the stores are
threaded (the v0.1.296 consumer did exactly that for four of them), but a
store accessed AMBIENTLY -- global helpers closing over it -- costs the
transitive closure of every function on the access path: 518 functions in the
first real program measured, on top of ~2100 direct call sites. A container
that can swap its own generation makes the entire question disappear: the
helpers keep their shape, the handle stays valid, and reclamation becomes one
call at a safepoint.

The discipline that makes it flat, measured: caller temporaries die in a
per-iteration `region` block, container churn goes at each compact -- 100k
writes churning ~5 MB on each side peak at 1.7 MiB. Compact-only reclaims
exactly the container's share (16.3 -> 11.6 MiB on the same probe with the
caller's temporaries left leaking, which are the caller's business).

One rule the types cannot enforce: pointers handed out by `map_get` /
`vec_get` before a compact dangle after it (the same safepoint discipline as
region loops -- compact where nothing borrowed is held).

parity 121/0 (new: map_compact -- interp, C and wasm agree; llvm refuses maps
as before), dune test 2541/0, ctest, stack_overflow, selfhost_check,
lsp_smoke.

---

## v0.1.296 — 2026-08-22

_A loop that carries its state between arenas._

`region R { }` is LIFO, and one thing genuinely does not fit LIFO: long-lived
state that is periodically compacted. A compaction copies the live set into a
NEW space and frees the OLD one -- the new generation must outlive the old --
and every attempt to write that with nested blocks puts the copy in a region
that dies first (or, iterated, in the enclosing region, monotonically). The ML
Kit hit this wall thirty years ago; it is the reason "region inference
degenerates to one global region" for non-LIFO programs.

`region R loop x { body }` is the hand-over-hand form. Each iteration runs in
a fresh arena named R. The body sees `x : option C` -- None on entry, Some
carry after -- and answers `region_flow[C, D]` (a new prelude type):
`Continue carry` deep-copies the carry into the next arena and releases the
current one; `Done d` copies d out and exits. The typing rule is the block's
with one split: **the carry may mention R** -- a `Map[R, ...]` crossing arenas
is the construct's whole point -- **the Done value may not**. No rigid type
variables were needed, though the road here assumed they would be: nothing of
arena N reaches arena N+1 except through the Continue copy, so the one name R
honestly denotes "the loop's current arena" in every iteration. The construct
the compaction story was blocked on turned out to be a loop, not a quantifier.

Continue's copy goes through a new family, `__mdeep_<tag>`: __mcopy with the
one difference that containers are copied into the target region instead of
passed as handles (a handle would dangle the moment the old arena is
released). A carried Map is rebuilt entry by entry -- `_set` re-hashes and
copies keys and values into the new arena, so the copy IS the compaction:
dead overwrites simply stay behind. What __mdeep cannot copy is refused at
emit time, by type: functions (captures hide behind a void* it cannot see
into), Channel, ThreadHandle, OwnedVec, StrBuf, ByteBuf.

Measured: 2000 cycles overwriting 50 map keys 1000 times each -- 2.4 GB of
dead entries churned, 51 entries live -- peak footprint **1.6 MiB**, 0.32 s.
The same shape without the loop is the monotonic default-region growth every
long-running Mere program has today.

Backends: interp and C; llvm / wasm / rv32 refuse cleanly (their reclamation
is a LIFO bump rollback, which cannot express the swap). Errors are typed:
a Done value mentioning R is a type error naming both rules; an uncarryable
type in C names itself and why.

parity 120/0 (new: region_loop_carry -- interp and C agree, llvm/wasm
documented-refuse), dune test 2541/0, ctest, stack_overflow, selfhost_check,
lsp_smoke.

---

## v0.1.295 — 2026-08-22

_One cached region is not enough once regions nest._

The per-thread cache of block-region structs was one slot deep. That is the
right size for regions that strictly alternate, and the wrong size the moment
they nest -- a loop iteration's region inside a statement's region, statement
regions inside the body -- because releases then arrive out of cache order: the
innermost release fills the slot, the next-outer release finds it full and
frees its region entirely (struct, 1 MB seed block and all), and the next
acquire at that depth buys them back. An interpreter built on this runtime
paid a 1 MB malloc+free round trip per loop iteration -- ~200 GB of allocator
churn over a 200k-iteration run, read from its own block counters. libc
absorbed it well enough that wall-clock barely moved, which is why it went
unnoticed until the counters said it out loud.

The cache is now a stack of eight. Deeper nesting than eight falls back to
malloc, which is correct and merely slower. The spawn trampoline drains the
whole stack at thread exit (same leak the one-slot drain existed for).

parity 119/0 (the first build broke it -- the thread-exit path still assigned
to the old single slot; the gate caught it before push), dune test 2536/0,
ctest, stack_overflow, selfhost_check, socket_parity, tcp_read_codes.

---

## v0.1.294 — 2026-08-22

_Every formatted value leaked its scaffolding._

Both native backends build a formatted string in an asprintf buffer, copy it into
the current region at the `__lang_str_of_cstr` boundary -- and never free the
buffer. One vasprintf buffer is 160 bytes on macOS, so a million `str_of_int`
calls leaked 48 MB. The list formatter was worse: it rolled its accumulator
through asprintf on every element (`__acc = __buf`), leaking the whole previous
prefix each step -- quadratic bytes in the list length.

Found from the outside: mere-ruby's new `bench/region_reuse.sh` asked whether a
region whose block chain GREW past one block hands its memory back in a reusable
form (the property a compaction loop stands on), and the answer looked like no --
peak footprint grew linearly, ~38 MiB per iteration, while the runtime's own
block counters insisted everything was returned. A minimal C probe cleared libc
(the same malloc/free pattern is flat at any iteration count), and `leaks`
named the 300,000 vasprintf buffers.

The boundary now has an owning twin: `__lang_str_take_cstr` copies into the
region and frees its argument. All 13 asprintf sites in the C backend and all 6
in the LLVM backend go through it; `getenv`/`argv`/literal sites stay on the
borrowing one. The C list/json formatters free their rolling accumulator.

After the fix the original question answers itself: released grown chains are
fully reusable through plain libc -- 1, 8, and 32 sibling ~64 MB regions all peak
at 36-39 MiB. No runtime block pool is needed.

parity 119/0, dune test 2536/0, ctest, stack_overflow, selfhost_check,
url/encoding parity, debug_info, wasm_sourcemap, lsp_smoke -- all run locally
before push, plus `leaks --atExit` reporting zero on the probe and on a
list-show program.

---

## v0.1.293 — 2026-08-21

_Whoever names a copier decides that it exists._

v0.1.290 taught `__mcopy` for an arrow type to deep-copy a closure's env, which
put copier CALLS in two places that had never emitted one before: a record's
copier, for a field holding a closure, and an env copier, for a captured value.
CI went red for four releases -- 16 of 119 parity programs, every `trait_*` one
among them -- with the emitted C naming a function that was never defined:

    v.mu_add = __mcopy_closure_int_closure_int_int(r, v.mu_add);   /* undeclared */

Two independent faults, each hiding behind the other's failure.

The first: **`ty_tag` names types that `ty_is_concrete` rejects.** `ty_tag` erases
an unresolved type variable to `int`, so a capture of `list (str, 'a)` is named
`__mcopy_list_tuple_str_int` -- while the collector that decides which copiers to
emit walks the same type, finds it not concrete, and drops it. A name with no
definition. Registration now goes through `ty_as_tagged`, which returns the type
`ty_tag` actually names, including the region slot that `ty_tag` renders as
`__heap` (erasing that to `int` would reintroduce the mpng P5 shape: one type
under two names).

The second: **a polymorphic record's fields were read three times, and two of the
readers had a different answer.** A trait dictionary `Num__dict 'a` is
monomorphized at its instance -- for `Num__dict m7` the struct field is
`closure_m7_closure_m7_m7` -- but the copier emitter read `r_fields` directly and
named `__mcopy_closure_int_closure_int_int`, the wrong type under the wrong name,
while the collector dropped the field entirely for holding a TyParam. Only the
closure-typedef collector, which had hit this before, substituted the arguments.
The rule now lives in one place, `record_field_types_at`, and all three read it.

Also: the inner-lifted half of the env-copier list is no longer filtered on
`captures = []`. A closure with no captures has no env at all and needs no copier;
an inner-lifted fn always gets an env struct and its use site assigns `__copy`
unconditionally. Measured, not reasoned -- restoring the filter fails exactly one
parity program (`prop_list`).

Gates: parity 119/0 (was 103/16), `dune test` 2536/0, plus ctest, stack_overflow,
host_matrix, selfhost_check, url/encoding parity, infer_scaling, debug_info,
wasm_sourcemap, lsp_smoke, window_check -- none of which CI had reached since
v0.1.290, because it stops at the first failing gate.

---

## v0.1.292 — 2026-08-21

_The copier moves into the env, and a closure is two pointers again._

v0.1.290 put the env copier in the closure struct, which made a closure three
pointers. v0.1.291 answered the cost by emitting two different closure shapes --
three pointers for programs that use a region, two for those that do not. That is
two rules where there should be one, and it left the memory win unavailable to
exactly the programs that wanted it: an interpreter that adds a region block to
reclaim its temporaries pays the pointer on every frame of its dispatch, and one
of CRuby's bootstraptest pairs loses its stack (`ld` caps -stack_size at 512 MB on
arm64, so there is no room to buy back).

The copier now lives in a header on the ENV: `{__lang_region* __r; void*
(*__copy)(__lang_region*, void*);}` at the front of every env struct. `__mcopy`
for an arrow reads it through the `void*` it already has. The closure struct is
`{env, fn}` again, for every program, and the region-conditional emission and the
typer flag it needed are gone.

An FFI adapter used to hold a borrowed pointer directly as its env, which a header
cannot be read from. Those envs are now real structs -- a header plus the borrowed
pointer -- allocated in the default region with `__copy = NULL`, which says "do not
copy me, I am permanent" in the same field that says "copy me like this" for a
generated env. One rule, read the same way everywhere.

Measured on an interpreter written in Mere: with a region block per statement, 200k
plain method calls hold 1181 MiB against 1358-1996 before, the same number three
runs out of three, and run in 1.16-1.20s against 1.43-1.58s. Its corpus is
157/157 either way.

**Two sentences in the first version of this entry were wrong, and the correction
is worth more than they were.** They said the memory win now costs nothing and
that CRuby's bootstraptest was back to its baseline. Neither holds: the pair
v0.1.291 was written around still fails with the closure at two pointers, so the
third pointer was not its cause -- or not its only one. That pair runs a thread
with `while true; // =~ "" end` beside a regex loop, and whether it finishes
depends on which limit trips first, the interpreter's step budget or the native
stack. The same source overflows at -O1 and does not at -Os: a canary on the
line, not a measurement of a change. The interpreter's own record now says so, so
that its err=59 is not read as a fresh regression.

The reasons to prefer this shape stand without those sentences: one closure
layout instead of two, no per-frame pointer, and an FFI env that answers the same
question the same way a generated one does.

2536 tests pass across four backends.

---

## v0.1.291 — 2026-08-21

_An env records its region, and a program that uses no region pays nothing._

v0.1.290 gave a closure a copier for its env and then copied unconditionally.
That is neither idempotent nor bounded. An env that captures a closure copies
that closure's env in turn, so a chain of them is a chain of copies, and a
threaded test in an interpreter written in Mere overflowed the native stack:
`stack overflow (recursion too deep)`, where the same program passed before.
Copying also duplicated identity — two copies of one env are two mutable
states, and a closure that writes through what it captured would write to the
wrong one.

Each env now carries the region it was allocated in, and the copier returns its
argument unchanged when that region is the destination. Copies inside one region
— the common case, and every copy in a program with no region blocks — become
no-ops, and a cross-region copy still walks only as deep as the chain that
actually crosses. This is the elision the memory model deferred as needing
type-level region tracking on values; one pointer per env does it at runtime.

Found by CRuby's bootstraptest, run against an interpreter written in Mere: 1697
pairs, of which exactly one moved from pass to error. Neither that interpreter's
own 157-program corpus nor this repo's 2533 tests noticed, because the shape
needs a closure captured inside a closure inside a thread. A wider gate is worth
having even when it is somebody else's.

The idempotence fixed the copying, and did NOT fix what the bootstraptest pair
was actually measuring: v0.1.290 made the closure struct three pointers instead
of two, and a closure is passed BY VALUE through every frame of an interpreter's
dispatch. One pointer per frame took that program over its stack limit -- and
there is no room to raise it, because `ld` refuses `-stack_size` above 512 MB on
arm64, which is exactly where the interpreter already was.

So the copier is now emitted only for programs that USE a region block. With no
region block `__lang_current_region` IS the default region, an env cannot outlive
its region, and the closure keeps its pre-v0.1.290 shape: two pointers, an env in
the default region, a shallow copy. Charging a cost to programs that cannot
benefit is the wrong trade, and the measurement said which programs those are.
Verified end to end: the interpreter rebuilt without a region block is back to
`pass=1569 err=58`, its baseline, and its generated C carries no copier field at
all.

The flag that answers "does this program use a region" is set by the typer, not
during emission -- the typer walks the whole program first, and a closure may be
emitted before the region block that appears later in the file. It is reset per
compilation, because the language server and the test harness both compile many
programs in one process, and a leftover `true` would give a region-less program
the shape of whatever was compiled before it.

v0.1.290 also shipped with `version.ml` left at 0.1.289: its changelog entry was
written after the suite ran, so the version test's failure was not seen before
the commit. Both are corrected here.

---

## v0.1.290 — 2026-08-21

_A closure carries the copier that lets it leave a region._

Closure environments were allocated in the default (program-lifetime) region, and
the reason was written where the deep-copy family is defined: "closures copy
shallowly: their envs live in the default region". A closure's env is a
type-erased `void*`, so nothing could copy it into another region — and a
permanent allocation was the only answer that could not dangle. The cost is
invisible in a small program and decisive in a large one: an interpreter written
in Mere allocated 2548 closure envs' worth of default-region references against
1346 current-region ones, so every call leaked whatever it closed over.

A closure now has a third member beside `env` and `fn`: `void* (*copy)(region*,
void*)`, generated per env type next to the env's own typedef, where the field
types are known. It region-allocates a fresh env, copies the struct across, then
re-copies each captured field through that field's own `__mcopy_<tag>` — so a
captured string is deep-copied rather than left pointing into the region that is
about to be released. `__mcopy` for an arrow calls it when it is set, and a
closure leaves a region block the way every other value does.

Two shapes deliberately keep the old behaviour, and get it for free from C's
zero-initialization of omitted designated initializers: a closure with no
captures passes `env == NULL`, and an FFI adapter holds a borrowed pointer it
does not own. Both leave `copy` zero and are copied shallowly.

The test that asserted the old rule now asserts the new one, in the same three
places it was checked: the allocation follows `__lang_current_region`, the
closure literal carries `.copy = __mcopy_env_...`, and a captured `str` reaches
the copier. 2533 tests pass across four backends; the change is C-only, since the
other backends do not share this representation.

What this does NOT do on its own: an interpreter with no `region` blocks has
`__lang_current_region == &__lang_default_region`, so nothing moves until the
blocks exist. It removes the reason they could not pay off.

---

## v0.1.289 — 2026-08-20

_A record field is a C struct member, and one name answered two questions._

The other half of the keyword surface. v0.1.286 routed a closure CAPTURE's name through
`c_safe_name`; a user record's fields never went through anything, so
`type t = { short: str }` emitted `const char* short;` — a keyword where a declarator belongs.
Same argument as v0.1.56's, which chose a uniform `mu_` prefix over a reserved-word list
because the list "was inherently incomplete and recurred six times", so the same prefix is
used and there is one rule to know rather than two. Fields live in a per-struct namespace, so
a prefix collides with nothing; what it buys is that no C keyword reaches a declarator.

Fourteen sites: two definitions (the struct body and the monomorphised one) and twelve uses —
literal, update, field access, pattern binding, `show_`, `to_json`, `from_json`, `eq`, `cmp`,
`__mcopy`, and a map key's equality and hash. Plus two hand-written runtime literals, for
`mk_logger` and `mk_metrics`, which spell the field names out and had to spell them the same
way.

**One real bug came out of doing it, and it is the interesting one.** `from_json` used the
same `fname` twice in one format string — once as the C designator and once as the JSON KEY.
Prefixing both renamed every key in every serialised record, which four parity programs said
immediately. The designator is an identifier and the key is what the document says; one name,
two questions, and only one of them wanted namespacing.

**And the loud-failure property earned its keep.** Eleven assertions in the suite pin this
struct's spelling from various sides and all eleven went red at once, which is exactly what
v0.1.56 argued a uniform prefix would buy: a path that forgets it breaks every record rather
than only the unluckily-named ones. Separating "the assertion is stale" from "the codegen is
broken" was one measurement — the four JSON parity programs compile and run — and after that
the assertions were bookkeeping.

Two sites were missed on the first pass and both were found by gates rather than by reading:
the `cmp` line, because the replacement written for it was character-identical to the original
and the patch skipped it, and `mk_logger`'s runtime literal. `host_matrix` named the second in
one line. `mk_metrics` is still `nocompile` on the C backend and was before this — a function
pointer type mismatch, unrelated.

Verified on Darwin: dune runtest 2531/0, parity 119/0, ctest 14/0, host_matrix with no
change, selfhost ok, stack_overflow ok. Verified on Linux in a container: fifteen programs
through the C backend and eleven through LLVM, including a record with `short`, `long` and
`inline` as field names, all matching the interpreter.

---

## v0.1.288 — 2026-08-20

_The LLVM backend names a stack overflow on Linux, which took `dlsym` and a computed array length._

Three releases and two wrong shapes to get here, all of them the same underlying fact: LLVM IR
has no preprocessor, so a runtime detail that differs by platform has to be selected at run
time or not at all.

v0.1.285 made the Darwin-only pthread pair `extern_weak` and guarded the call, which stopped
the link failure and left the bounds unknown off Darwin. v0.1.287 found that the handler was
not even being installed there — `stack_t`, `struct sigaction`, the `SA_*` values and `SIGBUS`
all differ — and selected seven measured constants off one `icmp`. What was left was the
bounds, and the obvious move does not work: declaring `pthread_getattr_np` `extern_weak`
breaks the DARWIN build, because Mach-O's linker refuses an undefined weak reference where ELF
resolves it to zero. Measured, not assumed — it was tried and reverted.

`dlsym(RTLD_DEFAULT, …)` asks at run time and needs no reference at link time, which is what
wanting an optional symbol actually calls for. Measured: it is in libc on both platforms, so
no extra link flag, and `RTLD_DEFAULT` is itself platform-dependent — 0 against -2 — which the
same `icmp` selects. glibc reports the LOW address and the size, the other way round from the
Darwin pair.

    platform         C backend    LLVM backend
    macOS/arm64      names it     names it
    Linux/x86_64     names it     names it
    Linux/aarch64    names it     names it

**So the divergence is gone and both the things that recorded it are gone with it.** The
parity pin for `uncaught_stack_overflow` is deleted, and `scripts/stack_overflow.sh` expects
one answer everywhere instead of a per-platform one — if a platform stops naming the fault
that is now a regression rather than a fact about the platform. The gate's second mode, for a
backend expected not to name it, is removed rather than left: nothing reached it, and a branch
nothing reaches cannot be told from a branch that is wrong.

One thing worth the line because it was caught late and cheaply: the three symbol-name
constants had their array lengths written out by hand and two of the three were off by one.
They are computed from `String.length` now. LLVM catches that, but only after the file is
emitted, and nothing about the source made it visible.

---

## v0.1.287 — 2026-08-20

_The LLVM handler installs itself on Linux, which needed seven measured constants._

v0.1.285 stopped the LLVM backend failing to link off Darwin by making the two Darwin-only
pthread calls `extern_weak` and guarding them, and left the fault unnamed there. What it did
not do was notice that the handler was not being installed at all: `stack_t`, `struct
sigaction`, the `SA_*` flag values and `SIGBUS` are all different on glibc, so `sigaltstack`
was handed a size where it expected flags, refused, and the early return meant no handler
ever arrived. The process died with the shell reporting the signal.

**The platform is a runtime fact here, not an emit-time one.** IR has no preprocessor, and
choosing when the IR is written would make `-ll` output specific to the machine that produced
it -- which it has never been. `pthread_get_stackaddr_np` is already declared weak, so its
address is non-null on Darwin and null everywhere else: one `icmp` and every constant below
is a `select`.

Measured on macOS/arm64, Linux/x86_64 and Linux/aarch64 rather than recalled, because a wrong
offset here writes a flag word into a signal mask and the handler simply never comes:

    si_addr in siginfo_t          24  /  16
    stack_t ss_size, ss_flags     8, 16  /  16, 8
    struct sigaction sa_flags     12 (of 16 bytes)  /  136 (of 152)
    SA_SIGINFO | SA_ONSTACK       65  /  134217732
    SIGBUS                        10  /  7

The observable difference on Linux is small and exact: `Segmentation fault` from the shell
becomes `segmentation fault` from our own handler, and the exit status becomes 1 -- what the
interpreter exits with -- instead of 139. So `parity`'s pinned divergence for
`uncaught_stack_overflow` moves from `EXIT(139)` to `MSG`: the process now fails the way the
interpreter fails and only the message differs. The pin catching that is what it is for.

**The name still needs the bounds, and that is one measured step away.** The glibc pair is
`pthread_getattr_np` + `pthread_attr_getstack`, and declaring them `extern_weak` does not
work: ELF resolves an undefined weak reference to zero and Mach-O's linker refuses it
outright, so adding them broke the Darwin build. `dlsym` with `RTLD_DEFAULT` is the portable
way to ask for an optional symbol, and `RTLD_DEFAULT` is itself platform-dependent (0 against
-2), which the same `icmp` can select. Not done here: it is a separate change with its own
verification, and shipping it half-measured is how this release's predecessor got the layout
wrong.

---

## v0.1.286 — 2026-08-20

_A capture the walker forgot, twice, and the shape that needs three things at once._

The browser dogfood is the first program here to ask the C backend to compile something
large, and it did not compile at all: 29 errors, in two families. The first was field names
not going through `c_safe_name` and is fixed above. This is the second, and it is the one
that had been invisible for a reason worth writing down.

**`known` decides what is NOT captured, and `host_locals` is what rescues a name from it.**
`known` is builtins plus top-level names plus externs — things referenced directly in the
generated C rather than through an env. `host_locals` is subtracted from it, which is how a
frame-local that happens to share a builtin's name gets captured anyway. The top-level
driver has always passed `[f.param]` for exactly this. Two places lost it.

**A curried parameter's name was discarded.** The walker's own `Fun` case read
`Ast.Fun (_, _, body)`, so descending through `fn (cs) -> fn (id) -> ...` recorded `cs` and
forgot `id` — and `id` is the identity builtin, so it sat in `known`, and an inner `let rec`
reading the parameter captured nothing. The lifted function then named an identifier that
was never declared, reported by the C compiler thousands of lines from the decision.

**And descending into a lifted body reset the list.** `walk_in_fn p [] fn_body` threw away
the enclosing frame's names, so one lift further in the outermost parameter looked like
something already in scope. One level worked because the enclosing frame was the top-level
one, whose parameter the driver had recorded.

**Three things have to line up, which is why neither showed up before.** The name shadows a
builtin; it is a curried parameter rather than the first one, or read from a nested lift;
and it is read from a lifted function. Any two of the three and the program compiles.

Two parity programs, one per defect, each verified to catch its own by reverting the fix.
The second was written with an ordinary name first and **passed with the fix reverted** — it
never reached the code it was for, and only poisoning said so. It names its parameter after
a builtin now, and the comment says why.

`MERE_LIFT_DEBUG=1` prints what this pass decided: per lifted function its host, parameter
and captures, and per lift the body's free variables alongside the names `known` blocked.
Kept rather than deleted after use — a missing capture surfaces as `use of undeclared
identifier` in generated C, and the alternative to reading this is guessing which of the
four skip conditions in the fixpoint fired.

The browser dogfood compiles now, and the measurement its north-star gate owed can be
taken: a 559-byte page in 45 ms, of which 19 is loading the font and 18 is style and
layout, at a 39 MiB high-water mark.

---

## v0.1.285 — 2026-08-20

_"On every backend" was verified on one platform, and CI said so for four days._

v0.1.271 named the stack overflow, and its title says "on every backend". It was true on
Darwin. On Linux it stopped the C backend compiling and the LLVM backend linking — every
program, not an edge case — and `parity` has been red since the commit after it. Four
consecutive days of failures, latterly hidden behind a stale version assertion.

**Three platform-specific defects in one runtime block.**

`pthread_getattr_np` is glibc's way to ask a thread for its stack, and glibc declares it
only under `_GNU_SOURCE`. Without the macro the emitted C called an undeclared function,
which clang 16 and later treat as an ERROR — and `-w`, which the parity harness passes,
does not silence an error. The `#define` now comes before every header, which is the only
place it works.

`static char __lang_sigstack[SIGSTKSZ * 4]` is a variable length array at file scope on
modern glibc, where `SIGSTKSZ` expands to `sysconf(_SC_SIGSTKSZ)` rather than a constant.
It is a literal 65536 now, comfortably above `MINSIGSTKSZ` on both platforms.

**And the one that had no preprocessor to hide behind.** The C backend picks between the
Darwin pair and the glibc call with `#ifdef`; LLVM IR cannot, so the Darwin names went out
on every target and nothing linked. They are `declare extern_weak` now and the call is
guarded: on Darwin they resolve and the fault keeps its name, and elsewhere they are null,
the bounds stay unknown, and the handler falls through to the plain segmentation fault it
already reported for a fault outside the stack. That costs the NAME off Darwin and nothing
else, and it needs no platform detection at emit time — so `-ll` output is still the same
file wherever it was produced. A name derived from an assumed stack size would be wrong for
any program linked with a bigger one, which is worse than no name.

**What let it through is the shape worth keeping.** The suite checks this feature by
looking for `stack overflow (recursion too deep)` and `sigaltstack` in the EMITTED TEXT.
Those assertions stayed green throughout, because a string is present whether or not the
file it is in compiles. `scripts/stack_overflow.sh` runs a program that recurses until it
dies and reads what it says, per backend, with the per-platform answers pinned rather than
smoothed over. It is in CI.

    platform   C backend                              LLVM backend
    Darwin     stack overflow (recursion too deep)    stack overflow (recursion too deep)
    other      stack overflow (recursion too deep)    a plain crash, no name

Measured on Linux in a container, not inferred: the C backend now compiles and matches the
interpreter on the first twelve parity programs, where before none of them built, and it
names the overflow there for the first time.

---

## v0.1.284 — 2026-08-19

_Generated inputs for the differential gates, and five NUL-length defects they found._

`contrib/prop` generates values; it does not compare them. A property test written with
it is an ordinary parity case, so the other four backends are the oracle and there is
nothing to commit as an expectation — the same shape as the browser dogfood's reftest,
moved from pixels to values.

Three decisions, each a way this could have measured nothing. It does not use
`random_int`: that builtin asks the host, five hosts would draw five sequences, and every
line would report DIFF while the gate reported on itself. Values are a function of an
**index** rather than a carried state, so a differing line in the diff already names its
input — which is why there is no shrinker, the smallest reproducer is `i` and it is
printed. Every intermediate stays below 2^45, because the interpreter's int is 63-bit and
the compiled backends' is 64-bit.

The edge tables are not a draw. Every integer defect this suite has found sat on one of
those values and a uniform draw reaches them with probability about zero, so a generator
that only drew would be weaker than the hand-written gates it extends. NUL is in the byte
pool on purpose.

### Five defects on the first run, all one family

Code that was correct while a `str` ended at its first NUL, and silently wrong after
v0.1.264 gave a `str` a length header.

| builtin | backend | what was wrong |
|---|---|---|
| `str_contains` | C, LLVM | `strstr` — a needle beginning with NUL matched every haystack |
| `str_index_of` | LLVM | `strstr` — answered 0 where the C backend's length-aware search answers -1 |
| `str_starts_with` | LLVM | `strncmp`, and no length check on the haystack — the only one of the four starts/ends implementations across the two backends written that way |
| `str_join` | C | the sizing pass asked `__lang_str_size` and the copying pass asked `strlen`, so an element holding a NUL was measured at its full length and copied only to the NUL. One function, two notions of how long a string is |
| `str_ptr`, `read_lines` | C | found by sweeping every `strlen` in the backend after the first four, not by waiting for a gate to point at them |

### Two recorded rather than fixed

Each pinned in its own case so it keeps being asked.

`test/parity/prop_utf8.mere` — UTF-8 character splitting. For `"A" ++ chr 128` the
interpreter says two characters and the three compiled backends say one, so `utf8_at`
returns two bytes and `codepoint_at` then refuses. Index 0 is `"A"` and what follows
cannot change that, so the interpreter is right. The span computation is prelude Mere,
one source compiled by all four, which means the difference is under it — a separate
measurement, not a guess to make while writing a test.

`test/parity/llvm_loop_guard_global.mere` — a loop whose bound is a top-level binding
stops after one iteration on LLVM. All three ingredients are needed and each was removed
in turn to check: the bound must be a top-level `let` and not a literal, the body must
evaluate a `try_or` whose thunk calls a prelude function, and it must be recursive. A
program folding this way would silently process the first element and report success.

### The axes are kept apart

`prop_int` leaves multiplication out and `prop_list` leaves `list_product` out, both with
the reason written down: their operands overflow, the interpreter wraps at 63 bits where
the compiled backends wrap at 64, and a gate measuring the width axis while claiming the
value axis reports the wrong one when either moves. `codepoint_at` moved out of
`prop_str` for the same reason.

`test_basic`: "llvm: declares strstr" asserted how `index_of` is implemented rather than
what it answers. It now asserts the `memcmp` and that `strstr` is absent.

Gates: unit 2527-0, parity 117-0 + failing 15-0 (5 declared divergences), ctest 14-0,
selfhost 7-7, html_tokenizer ok.

---

## v0.1.283 — 2026-08-18

_Two shadowing bugs, and a gate whose expectation was degenerate._

Both bugs had the same shape: **the compiled backends resolve a name globally, and
something shadowed it.** The interpreter was right in both cases, which is what made
them findable at all.

### Q-045: a user binding that shadows a builtin the prelude calls

```mere
let show = fn (x: int) -> x + 1;
print (str_of_int (show 1))
```

Three lines, and it made the **prelude** fail to type — `expected 'str', got 'int'` at
`<prelude>:485` for a program that never mentions the prelude — on all four compiled
backends. The prelude's `pow` calls the `show` builtin. Not `show`-specific: `str_len`
and `list_len` are each called three times in there.

**Two independent causes, and the first hid the second.**

The desugared program was typed against the **accumulated** environment. Since
`desugar_program` turns every `Top_let` into a nested `Let`, the expression rebinds all
of them itself — so passing the accumulated environment added nothing except the one
thing it must not: *a binding visible to declarations that come before it*. It now types
against an environment holding only what desugaring **drops**, which is externs.

That turned the error into a refusal from the monomorphiser, because
`uniquify_toplevel_shadows` never saw the user's `show` as a shadow — a builtin is not
a top-level declaration, so the first binding of that name kept it. It is seeded with
the builtin names now, so the user's binding is renamed and references *before* it — the
prelude's — still mean the builtin.

The seed subtracts the prelude's own top-level names: the prelude deliberately shadows
ten builtins (`pow`, `divmod`, `assert`, …) and those keep the names they have always
had.

### Q-046: a parameter named the same as a top-level binding

`uniquify_inner_fns_expr` renames inner **fn** bindings that collide with a top-level
name, and left `Fun` **parameters** alone. So a lifted inner function took no parameter
for its captured `handler` at all, and its body referred to the caller's global of that
name.

**It was invisible while both had the same type** — the wrong binding happened to fit —
and surfaced as C that would not compile only when the types diverged. `contrib/http2`
carried a naming workaround for it; the parameter is renamed now, so that workaround is
a comment about history rather than a rule.

Parameters get a different treatment from inner fns and the distinction is the point: an
inner fn becomes a symbol and must **reserve** its name, a parameter does not and only
has to **not be mistaken** for one.

### Three test assertions were pinning a symbol name

`§30.0` checked that a user-defined `is_alpha` shadows the builtin by grepping the output
for `int mu_is_alpha(`. The fix renames it to `is_alpha__v2`, so they matched the prefix
instead. Measured before changing: the compiled program answers `true` and the builtin
answers `false` for the same input, so the behaviour under test was unaffected — the
exact name only said it by accident.

### The line-break gate was comparing against nothing

`linebreak_conformance` reported **19338 of 19338 cases differing**. `want.txt` had
19338 lines and **not one break mark in it**: under this machine's `LANG=ja_JP.UTF-8`,
awk 20200816 compares `÷` **equal to** `×` — collation, not bytes — so every mark became
`×`.

The implementation was right and the **expectation** was degenerate. It runs under
`LC_ALL=C` now. It passes on GNU awk and under the C locale, which is why CI was green
and a Japanese-locale machine was not — the environment difference to suspect first when
a gate disagrees with CI. The data is ASCII plus those two symbols, so byte comparison
was what was wanted all along.

Verified: 28 CI gates, `runtest 2526/0`, `parity 110/0 + 15/0` (two new parity programs),
`selfhost_check all passed`, `host_matrix ok`.

## contrib — GraphQL introspection and validation — 2026-08-18

_No compiler change. `contrib/graphql`, two new gates._

### Introspection is answered by the ordinary executor

`__schema`, `__type(name:)` and `__typename`. The introspection types are **ordinary
SDL**, generated from graphql-js into `introspection_sdl.mere` and *appended to the
document's own definitions* — so `__Type` is an object type like any other and field
lookup, nullability, null propagation, list handling and enum coercion all apply to it
unchanged. One line, and there is no second executor.

The SDL is generated and committed, like the Unicode and HPACK tables: the
specification fixes every name, type and nullability, and a 200-line transcription has
a mistake in it.

**Introspection is cyclic, so one value has to be lazy.** `__schema.types` lists every
type, each type's `fields` name types, whose fields name types; a strict value cannot
hold that and eager construction does not terminate. What bounds the expansion is the
query — `getIntrospectionQuery()` asks for `ofType` exactly nine levels deep. So
`gvalue` has one non-data arm, `GTypeRef of gtype`, computed when asked for: the only
place in this executor where a field is computed rather than looked up.

**The strongest check is not a comparison.** Our introspection result fed to
graphql-js's own `buildClientSchema` and printed must equal
`printSchema(buildSchema(sdl))`. It holds exactly when our answer carries the whole
schema, it is blind to field order (which the specification does not fix), and nothing
transcribes an introspection result. It passed *before* the JSON comparison did, and
both differences that then surfaced were real:

- **A built-in scalar belongs to a schema only if something refers to it.** The
  oracle's type map for `type Query { a: Int }` is `Query Int Boolean String` and not
  the other two — `Boolean` and `String` because the **built-in directives** refer to
  them, which falls out of walking the appended SDL rather than being special-cased.
- **graphql-js 17 keeps an argument's default in `a.default.value`**, not
  `a.defaultValue`. Reading the old field silently dropped `@deprecated`'s default.

**`includeDeprecated` defaults to false**, and the standard introspection query passes
`true` — so every gate section using it agreed while that was missing entirely. It took
a hand-written `__type(name: "Colour") { enumValues }` to disagree.

### Validation, and how a partial validator is gated

19 of the specification's 32 rules. The gateable part is the design:

**Every error carries the name of the rule that produced it**, and the harness compares
the *set of rule names* against graphql-js running each of its 32 rules individually —
the oracle classifying its own output. Not the error list, for two measured reasons:
graphql-js returns errors in visitor order interleaved across rules, so a partial
validator could never agree about anything; and rule names are about thirty identifiers
from the specification's own section titles, small enough that a shared misreading is
not a real risk.

Three failures, not one: rejecting what the oracle accepts (**the worst** — a false
positive fails a valid request), missing a rule we *claim*, and missing a rule we do
not claim (DOCUMENTED-GAP, and the rule must be listed). **A gap-list entry that never
fires fails the harness as stale.**

The claim list is checked **in both directions**: every rule reported must be on it.
Without that, dropping a rule from the list while still implementing it left the
harness green — poisoning found it, because the list is otherwise consulted only for
rules that were *missed*. A wrong list silently weakens every check that reads it.

**The document and the schema are separate arguments**, unlike the executor.
`ExecutableDefinitions` is the rule that a document being executed must not contain
type-system definitions, so a combined list makes every schema violate it — the first
version reported every SDL type as "not executable".

What the harness caught: we rejected `{ __schema { queryType { name } } }` because
`__schema` / `__type` / `__typename` are provided *by* the schema rather than declared
in it; `is not defined **by** operation` versus `is never used **in** operation`, two
prepositions and one helper that put the wrong word in one of them; and a fragment
cycle is reported *once*, at the first fragment in document order.

### A harness bug worth naming

Comments inside a node script passed in a double-quoted shell string may contain
**neither a backtick nor a double quote** — one is command substitution, the other ends
the string. Both mistakes were made in consecutive edits. The second turned the
comparison into a syntax error rather than a wrong answer, which is the good failure of
the two.

## contrib — HTTP/2 flow control and gRPC streaming — 2026-08-18

_No compiler change. `contrib/http2`, `examples/grpc_hello.mere`, and two gates._

Both directions of the flow-control window, `SETTINGS_MAX_FRAME_SIZE`, and gRPC
methods that send or receive more than one message. `grpcurl` now gets
server-streaming, client-streaming and bidirectional answers from a Mere server, and
a 300 KB request and a 300 KB reply both go through.

**The limits bite in an order, and the first one is not a window.** Measured against
a python `h2` client before any of the code existed:

| bound | bites at | what the client does |
|---|---|---|
| `wbuf` capacity, unchecked | 16385 | **nothing** — wrote past the buffer, returned success |
| `SETTINGS_MAX_FRAME_SIZE` | 16385 | refuses the frame outright |
| the flow-control window | 65536 | accepts no more DATA until it grants credit |
| inbound, the same window | 65536 | stalls at exactly 65535 with nothing from us |

A fix that added window accounting without splitting frames would still have failed
at 16385. The `wbuf` row is the one with no symptom at all: `mem_copy_bytes` is a
`memcpy` into a bump arena that records no allocation sizes, so nothing below could
catch it. Demonstrated with a sentinel — 32 bytes into a 16-byte allocation changed
the byte after it and reported 32.

**Flow control makes the writer a reader.** A send whose window is exhausted has to
consume the `WINDOW_UPDATE` that reopens it, so `send_data` contains a reader.

### An export list is not a coverage list

`H2.read_settings` read each SETTINGS entry's 32-bit value at offset `i+4` instead of
`i+2` — two bytes past every six-byte entry, so the last entry of any payload read
off the end. Wrong for as long as the file has existed, and **nothing called it**:
the writer had a parity section from the start, the reader was exported, documented,
and never fed a byte, and the server's own comment said its peer's settings were
"read and ignored". The first caller found it on the first connection, at byte 42 of
a 42-byte payload.

Enumerating every export and counting call sites turned up a second accessor in the
same state — `H2.error_code`, zero callers and zero coverage. It happens to be right.
`http2_parity.sh` now feeds every payload accessor.

### What poisoning found that valid traffic could not

- **A well-behaved client cannot see a server that ignores its window.** Poisoning
  the check to "a billion bytes" left the section green: a client that acknowledges
  as it reads has already granted more credit by the time the next chunk arrives. The
  gate now has a rude client that advertises 8192 and stops reading.
- **`SETTINGS` adjusts a spent window by the delta; it does not reset it** — and the
  two rules agree exactly when nothing has been spent. The SETTINGS now arrives
  mid-response, driving the window to **-57343**; negative is legal, and a reduction
  after credit was spent is the only way to get there.
- **The SETTINGS branch of the window-wait loop recursed under a comment saying it
  returned to its caller.** A peer may reopen a stalled stream with `SETTINGS` alone,
  and this server would have waited forever. Found only because the delta poison was
  undetectable for the same reason.
- **One rule was written twice.** A `WINDOW_UPDATE` increment of 0 is a protocol
  error; the frame loop ignored it and the window-wait loop failed on it. The wrong
  one was on the path every ordinary frame takes.
- **`SETTINGS_MAX_FRAME_SIZE` could not bind.** Its minimum *is* the default, so with
  a 16384-byte write buffer `min(peer, capacity)` was always the capacity and reading
  the setting could not change the answer. The buffer is 65536 now, which makes the
  term live rather than deleting it.

### Two wrong expectations, both the same slip

The boundary in the *field* is not the boundary on the *wire*: a 16384-byte reply
field is 16393 bytes of DATA once the gRPC prefix, the protobuf tag and a 3-byte
varint are added, so it already needs two frames. That got the frame-count
expectation wrong, and later a window grant that left the server nine bytes short.

Also `h2`'s `local_settings.initial_window_size = ...` is silently ignored before
`initiate_connection` — the client advertised 65535, the server correctly sent 65535,
and the harness blamed the server.

### Streaming is the list having more than one element

The handler takes the request's messages as a `bytes list` and answers `RpcOk`,
`RpcStream` or `RpcErr`; `H2Server.unary` adapts a one-in-one-out handler. There is
no separate path for client-streaming. Interleaving is **not** supported and is said
so rather than approximated: the handler runs after the request half-closes.

`examples/hello.proto` gained five methods and `contrib/proto` needed no change —
`stream` was already parsed, and our descriptor for the new schema matches
`protoc` byte for byte.

## v0.1.282 — 2026-08-18

_The FFI byte arena gets a `bytes` bridge._

`mem_to_bytes` / `mem_copy_bytes`, the arena's two directions for data that may
contain a **zero byte** — which `mem_to_str` cannot carry, because it stops there,
and which every binary protocol has. Native and Wasm-component both, and
`scripts/socket_parity.sh` requires the two to agree.

**What it replaced.** `contrib/http2/server.mere` was reading arena → hex → `bytes`
(two characters per byte, three passes) and writing with **`mem_set_u8` once per
byte**. The write is the one that mattered: a response is now one FFI call instead of
one call per byte of it. Same shape as v0.1.222, where `file_pwrite` could not take a
`bytes` and built one boxed int per byte.

The Wasm helper is a few instructions because the arena *is* linear memory there. The
one thing to get right is that a `bytes` pointer points **at the length**, where a
`str` pointer points at its data with the length at `ptr-4`; a comment says so, and
poisoning the layout both ways is caught.

**Two mistakes, and the second is the interesting one.**

First, the definitions went where the rest of the arena lives — and the generated C
said `unknown type name 'mere_bytes'`, because `b->data` needs the complete struct
and that block is emitted earlier. So they moved into the bytes runtime.

Then they were emitted there **unconditionally**, and `__mem` — the arena — is only
emitted when a program declares an arena extern. Every program that uses `bytes`
*without* the arena stopped compiling, which is most of them; `proto_parity` said so
on the next run. **Two independent conditions, and satisfying one is what made the
other easy to miss.**

The gate for that turned out to need one more thing: `bytes_runtime` was a top-level
constant, evaluated at module-initialisation time — *before any program is parsed* —
so a `Hashtbl` lookup inside it would have been false for every program that ever
declared the externs. It takes the flag as a parameter now.

Poisoning found a coverage gap too: reading the length with `i32.load8_u` instead of
`i32.load` passed, because on a little-endian machine the low byte of a length under
256 **is** the length, and every payload in the corpus was shorter than that. There
are 255-, 256- and 300-byte payloads now.

## v0.1.281 — 2026-08-18

_IEEE-754 bit access, in two halves because one would not fit._

`float_bits_hi` / `float_bits_lo` / `float_of_bits`, and `f32_bits` /
`float_of_f32_bits` for float32. All five on all four backends, closing the last
thing that stopped a protobuf `double` or `float` field from being generated.

**The API shape was measured, not chosen.** The obvious design is one accessor
returning the whole 64-bit pattern. It does not work: read as a signed int64, a
double's pattern exceeds this interpreter's native int — which is OCaml's, and
63-bit — for a large share of ordinary values. `-1.5`, `1e308`, `inf` and `nan` all
do. A single accessor would therefore answer differently on the interpreter than on
every compiled backend, for a literal as plain as `1e308`, and the honest options
were a DIVERGE pin or a different API. Two 32-bit halves are each below 2^32, so
there is nothing left to diverge about — and they are also exactly what a wire
format wants, since it writes the bytes anyway.

`f32_bits` narrows to float32 with the **backend's own** double-to-float conversion,
which is round-to-nearest-even. That matters more than it sounds: `1e308` has no
float32, and the answer is `+inf` rather than a wrapped number. Writing that
rounding by hand is the part nobody should have to get right twice.

`contrib/proto/wire.mere` gains `put_double` / `get_double` / `put_float` /
`get_float` on top, so the split stays inside that layer and neither a caller nor a
generated codec learns about it. The generator's refusal of `double` and `float` is
gone, and `scripts/proto_gen_parity.sh` covers them — 25 schemas now, including
`1e308`, `1e-308`, float32's maximum, and repeated floats, all byte-identical to
protoc.

**Two mistakes worth recording, both mine and both in the checking rather than the
code.**

The Wasm arm shifted with `i64.shr_s`. The top bit of a double's pattern is its sign
bit, so an arithmetic shift sign-extends it and `float_bits_hi (-0.0)` came back as
`-2147483648` — a value that then compares as negative and divides the wrong way, on
that backend only. It is `i64.shr_u`, and the comment now says why.

Finding it took two detours. First I read a stale binary: `dune build 2>&1 | head -2`
had exited on SIGPIPE, so the compiler under test was the poisoned one from a
mutation run that a timeout had killed mid-restore. Then I "verified" the restore
with `grep -c 'i64.shr_u'`, which returned 1 — from a *different, pre-existing*
occurrence elsewhere in the file. **A check that cannot tell the two states apart is
not a check**; the verification is anchored to the arm now.

`test/parity/float_bits.mere` pins every class — normal, subnormal, both zeros, both
infinities, NaN, the range ends — on four backends. NaN is checked through its bits
rather than through `==`, because `==` on NaN is false by IEEE and comparing it the
obvious way reports a failure that is the comparison's own rule.

## 2026-08-18 — A protobuf code generator, and two branches nothing reached

_`contrib/proto/gen.mere` + `examples/protoc_mere.mere`: a `.proto` in, Mere source
out. `examples/grpc_hello.mere` now uses it, and its hand-written codec is gone._

```sh
mere examples/protoc_mere.mere examples/hello.proto ../contrib/proto/wire.mere \
  > examples/hello_pb.mere
```

The codec in that example used to be a hand-written field walk and a two-line
encoder. Both were correct, and both were a schema transcribed by hand — which is
the thing a generator exists to stop.

`scripts/proto_gen_parity.sh` runs protoc's bytes through the generated codec and
back: `protoc --encode` → `decode_M` → `encode_M`, byte-compared. 20 schemas. A round
trip through the oracle's bytes catches more than it looks like, because a field the
decoder ignores cannot be written back and shows up as a shorter byte string. The one
thing it cannot see is a consistent swap of two fields holding equal values, so every
field in the corpus has a distinct value.

**Three representation choices, each forced by proto3 rather than chosen:** a singular
message field is a 0-or-1 list (message fields have explicit presence, so "absent" and
"present but empty" differ — and it makes a recursive message expressible); an enum is
an `int` and not a variant (a proto3 enum is *open*, and an unknown number has to
survive a round trip); and a generated identifier never begins with the type name,
because uppercase-leading is how this language recognises a constructor — `M_get_a`
parses as one and is reported as an unknown constructor at its *use* site, naming
something the schema author never wrote.

The encoder writes fields in **field-number order, not declaration order**, because
protoc does.

**Poisoning found two branches nothing reached:**

1. **The repeated zigzag and fixed families were not in the corpus.** It had *singular*
   sint32 and *repeated* sint64, so the repeated-sint32 path was generated and never
   executed — breaking it changed nothing.
2. **protoc always writes packed, so the decoder's unpacked branch was never reached.**
   proto3 requires a decoder to accept both forms whatever the writer chose, and
   deleting that branch left the harness green. A decoder that only understands the
   encoding its own oracle emits works against exactly one kind of writer.

The second one needed input protoc does not produce, so the harness builds it — and
the first hand-typed version had field 2's tag as length-delimited, which protoc
rejected and the harness reported as its own bug, correctly. **Hand-written test bytes
are a transcription like any other**, so they are computed from the values now. protoc
is then *asked* whether the two spellings mean the same value rather than being told.

## 2026-08-18 — A .proto parser, and the bootstrap closing

_`contrib/proto/parse.mere` + `contrib/proto/descriptor.mere`: a `.proto` file in,
a `FileDescriptorSet` out, byte-identical to `protoc --descriptor_set_out` across 72
derived files._

**The bootstrap closes here, and that is why it is one harness rather than two.** A
descriptor set is itself a protobuf message, so the code that reads a schema is
serialised by the code that reads wire bytes. If the varint encoder is wrong, this
diff says so; if a descriptor field number is wrong, the same diff says so. One
oracle checks both layers at once.

The comparison is bytes. A descriptor that decodes to the same text but different
bytes is still a different descriptor to anything that hashes or caches it.

**Three things were measured off the oracle before anything was written**, and each
would have been wrong from memory:

* **`descriptor.proto` is proto2, which reverses a rule the wire harness had just
  learned.** A set field is written even at its default, so an enum value's
  `number: 0` appears on the wire — where proto3 omits a scalar holding its default
  and `v: 0` could not be swept at all. Same encoder, opposite rule, decided by the
  schema being encoded rather than by the encoder.
* **`json_name` is not plain camelCase.** `my_field` → `myField` is the easy one;
  `a_b_c` → `aBC`, `trailing_` → `trailing`, `__lead` → `Lead` and `num_2_x` →
  `num2X` are the ones a guess gets wrong. The rule is "drop underscores, upper-case
  what follows each one".
* **`type_name` carries a leading dot and is fully qualified**, and a reference
  resolves from the innermost scope outward — so the same simple name is a different
  type at a different depth, and the wrong order still produces a well-formed
  descriptor.

**The last of the 72 files to match differed by two bytes.**
`rpc U (Q) returns (R) {}` is not the same as `rpc U (Q) returns (R);` — the empty
body sets `MethodOptions` to an *empty submessage*, so protoc writes `22 00` there
and nothing for the semicolon form. Presence with no content is the whole
difference.

**The subset is refused, not skipped.** `oneof`, `map`, `import`, `option`,
`reserved`, `optional`, `extend`, `group` and proto2 are outside it, and protoc
accepts every one — so the oracle cannot be asked whether they are wrong. The
harness checks instead that each is refused **by name**, because a skipped construct
produces a descriptor that is wrong where nothing looks. Getting that right needed
two fixes the corpus found: an absolute type reference (`.pk.M`) is a different
production from a name and needed its own reader, and a field option list met
"expected ';'" — a syntax error about a file that is syntactically fine — until it
was given a named refusal.

Ten poison mutations, none uncaught.

## 2026-08-18 — RPC statuses, and an expectation the wire corrected

_A gRPC handler can now fail._

`bytes` alone could not say "this failed", so an unknown method got a reply that
looked like a success. A handler now answers `RpcOk of bytes` or
`RpcErr of (int * str)`, and a failure goes out as a status in the **trailers** —
the request succeeded as HTTP and failed as RPC, so it cannot be expressed as a 4xx,
and a failed unary call carries no DATA frame at all.

**`grpc-message` is percent-encoded**, which is neither optional nor cosmetic: the
specification says so and grpc-go *decodes* it. Measured before implementing —
`caf%C3%A9 %25 done` came back as `café % done` — so a raw `%` would have been read
as the start of an escape.

**And then the wire corrected the harness.** The first expectation written for the
raw trailer assumed a space and an apostrophe would be encoded. They are not: the
rule is "bytes outside printable ASCII, plus `%` itself", the same as grpc-go's own
encoder. The implementation was right and the expectation was a guess; the failing
diff is what said which.

The DOCUMENTED-GAP that asserted the *absence* of statuses did its job on the way
out: closing the gap made that assertion fail and report itself stale. Three routes
are checked in its place — a method the schema declares and the server does not
handle, a method that exists and refuses its input, and a message that needs
encoding — and the python client now reads the **raw** trailers. That is the
observation grpcurl cannot give: it prints the decoded message and the rendered code
name, so whether the encoding happened is invisible there. Poisoning found nothing
uncaught across five mutations, including lower-cased hex digits.

## 2026-08-18 — A GraphQL executor, and the one case out of 67 that mattered

_`contrib/graphql/exec.mere` plus `scripts/graphql_exec_parity.sh` against
graphql-js's `execute()`._

**The resolvers are the data.** A field is resolved by looking its name up in the
parent object, which is graphql-js's default. Both sides get the same schema, the
same document and the same root value, so **nothing about resolution is
transcribed** — two hand-written resolver sets would drift and the drift would look
like an execution difference.

What that arrangement really exercises is **null propagation**, and it is why an
oracle earns its place. A non-null field that resolves to null is not an error in
that field: it destroys the nearest **nullable** ancestor. `{ nn }` answers
`"data": null`. An item error in `[Int!]` nulls the whole list with a path of
`["ln", 1]`. All of it was measured off the oracle before being implemented,
because reading behaviour off a specification and reading it off a running
implementation are different activities.

Every position is one of two things — `GOk (value, errors)` or `GBubble errors` —
and the four cases in the specification fall out of those two constructors instead
of needing exceptions the language does not have.

**Of 67 corpus cases exactly one differed, and it was the interesting one.**
`{ o2 { nnx } }` with `o2: O!` produced *two* errors: the real one about `O.nnx`
and an invented one about `Query.o2`. The oracle produces one. When a non-null
position is null **because an error already propagated**, no second error is
raised — the check that would raise it is never reached, because the propagation
went past it. The fix splits the job: `raw` completes a position with no absorbing,
and `complete` decides what the position's nullability means. A list item goes
through `complete`, so `[O]` nulls the item and `[O!]` nulls the list, which now
falls out rather than being special-cased.

Poisoning the gate ten ways caught nine immediately. The tenth is worth recording
as a coverage lesson: breaking the **named** fragment's type-condition check went
unnoticed because the corpus only had the **inline** form. Two nearly identical
branches, one of them unchecked. Three named-spread cases closed it, and the
poison then failed as it should.

Error messages are compared verbatim — the specification does not fix the prose, so
matching the reference implementation is the only way to compare them at all, and
the oracle is pinned. `locations` are stripped from both sides: they need source
positions the parser does not carry, which is a stated gap rather than an accident.

## v0.1.280 — 2026-08-18

_A capture whose name has a dot in it._

An inner `let rec` that referenced a module-qualified name put that name into the
closure's environment struct verbatim, so the C backend emitted

```c
long long Wire.delimited;
```

and the generated C failed to parse. **The error pointed at a line the program did
not contain**, which is the part that makes this worse than a refusal: the
diagnostic was about generated C, not about the source that caused it. The
interpreter was always correct, so nothing saw it until a dogfood compiled a
wire-format decoder with `Wire.delimited` inside a field-walking loop.

The shape is narrow, and measuring which variants were affected is what located it.
Four were fine — `M.k` at the top level, a top-level closure using it, that closure
passed to a function, and an inner `let rec` capturing only its enclosing
parameter. Only an inner `let rec` referencing a qualified name reaches the
environment-struct emitter instead of being referenced directly.

**The fix is that two paths now agree.** The inner-LIFTED environment
(`__env_local->…`) already ran capture names through `flatten_module_dots`; the
anonymous-closure environment did not. Three sites — the struct's field
declaration, the adapter's substitution, and the creation site that fills the
environment in — now flatten too, with the substitution still *keyed* on the name
as written because that is what `Var n` in the body says.

`flatten_module_dots` is the identity for a name without a dot, so **every program
that did not hit this emits byte-identical C**. And every output that does change
was previously invalid C — a dot in a field name has never been legal — so there is
no program whose working output moved.

`test/parity/module_qualified_capture.mere` pins it on all four backends, including
the variants that were *not* broken, so a future change cannot fix one path and
regress the other.

## 2026-08-18 — A gRPC server in Mere, and two bugs loopback was hiding

_`contrib/http2/server.mere` plus `examples/grpc_hello.mere`. `grpcurl` asks a Mere
server for a greeting and gets one._

```
$ grpcurl -plaintext -protoset hello.protoset -d '{"name":"mere"}' \
    127.0.0.1:50079 hello.Greeter/SayHello
{
  "message": "hello mere"
}
```

Everything under that line is Mere: the protobuf wire format, the HTTP/2 framing,
HPACK, and the connection. TLS is absent by measurement rather than oversight — h2c
is what `grpcurl -plaintext` speaks, 24 literal bytes and no negotiation.

`scripts/grpc_parity.sh` is the first harness here that does not compare bytes.
Every layer underneath already has a byte-level gate; none of them answers whether
a client that knows nothing about any of it gets a reply it recognises. Two clients,
because they ask different questions: `grpcurl` (Go) over four connections
including an empty proto3 request, and a python `h2` client making three requests on
**one** connection — the case grpcurl cannot express for a unary method, and the one
that catches a per-stream HPACK decoder.

**Poisoning it found two bugs that every other section passed:**

1. **Removing the frame reassembly changed nothing.** On loopback a request arrives
   in a single read, so a server that parses whatever one read handed it works. The
   comment in `server.mere` had said reassembly "is not a simplification, it is a bug
   that happens to pass on a fast loopback" — and the harness proved the comment
   right by failing to catch its removal. The python client now sends one request
   **split every seven bytes**, so the 9-byte header itself straddles two reads.
2. **Removing the SETTINGS acknowledgement changed nothing**, because neither client
   blocks on it. The client now asserts the ACK arrives.

Both are the mirror of the dead guards found in `frame.mere` yesterday: there, code
that nothing reached; here, behaviour that nothing observed.

**Two harness bugs were worth more than they cost.** The readiness check waited for
the port *by connecting to it* — which the server counts, since it serves a bounded
number of connections and then exits, so the probe ate one and the last real call
got "connection refused" while the harness blamed the server. It waits for the
server's own "listening" line now. And the unknown-method section printed its
DOCUMENTED-GAP without calling anything: a claim, not a check. It calls a method the
schema declares and the server does not handle, and requires the documented answer.

**One compiler bug came out of writing the example** and is recorded rather than
fixed: an inner `let rec` that references a module-qualified constant makes the C
backend emit the qualified name as a struct field — `long long Wire.delimited;`,
which is not valid C. Six lines reproduce it, the interpreter is correct, and the
error names generated C rather than the program that caused it.

## 2026-08-18 — HPACK, and three ways a gate can pass without checking anything

_`contrib/http2/hpack.mere` plus a generated table and a seven-section gate. The
implementation went green on the first run; poisoning it is what produced the
interesting part._

**What had to be complete was measured.** grpcurl 1.8.8's first HEADERS frame on a
real connection uses static-table indices, Huffman-coded literals and **seven**
dynamic-table insertions — so the decoder is complete (integers, both string forms,
all five instructions, eviction) while the **encoder is trivial**: literal, new
name, no indexing, no Huffman, which RFC 7541 permits and which a real client was
confirmed accepting end to end. That asymmetry is why a gRPC server is reachable
without writing a Huffman encoder.

The dynamic table is connection state and is **threaded through the API** rather
than hidden in a global, because one decoder per connection is correct and two is
not, and a parameter makes that visible at the call site.

**The tables are generated from the same library the gate uses as its oracle**,
which is a hole a differential test cannot close: a shared transcription error is
invisible. So one section decodes a header block **captured from grpc-go 1.57** — a
third implementation, in another language, that never saw either table. Nine header
names and the table's own accounting come back matching.

Then the gate was deliberately broken, nine ways. Six were caught immediately. The
other three were the point:

1. **Valid input does not test a refusal.** Removing the Huffman padding check
   changed nothing, because well-formed blocks have well-formed padding. Nine
   malformed blocks now exercise the refusals — the same lesson the GraphQL
   reject-list taught, arriving again in a different file.
2. **"Does it refuse" and "does it say what was wrong" are different questions.**
   Removing the index-0, EOS and string-length checks *still* refused, further
   downstream, with a message about something else — so the gate stayed green while
   three named diagnostics had been deleted. Each malformed case now asserts a
   substring the refusal must contain. That couples the harness to *our own*
   wording, which is the acceptable direction; coupling it to the oracle's would be
   brittle for no gain.
3. **A check whose input never arrives passes.** The case file was written with two
   columns while the reader expected three, so every expectation was the empty
   string and `grep -q ""` matched every message. An empty expectation is now a
   failure in itself — and so is a reject-list that checked **zero** cases, which
   is the rule the builtin matrix learned in another form: a gate reporting ok for
   no cases cannot be told apart from one that did not run.

One line survives poisoning on purpose. `len2 < huff_min_len` is a **fast path, not
a check** — `huff_count` already answers 0 below the minimum length — and it is
labelled so the next reader does not have to work that out. The contrast with the
`lshr` mask deleted yesterday is deliberate: that one was a guard that could not
fire, this one is an optimisation that provably cannot change an answer.

## 2026-08-18 — GraphQL's type-system half, and HTTP/2 frames

_`contrib/graphql` grows SDL; `contrib/http2/frame.mere` arrives with a gate
against hyperframe. Both gates were then deliberately broken to see whether they
could fail, and both had blind spots._

**SDL** — schema / scalar / type / interface / union / enum / input / directive,
with descriptions, `implements A & B`, argument definitions and defaults. The
derived corpus goes from 153 to 366 documents and the round-trip covers all of it
unchanged, because graphql-js's `print` handles type-system definitions too.

Then the half that was missing: everything so far fed **valid** documents, and a
parser that accepts anything passes all of it. A reject-list of 37 documents the
oracle rejects found six real defects on its first run:

* `{ }`, `type T { }`, `enum E { }` and `input In { }` were all accepted. Every
  delimited list in this grammar needs at least one element **except the two that
  are values** — `[]` and `{}` are legal, `{ }` as a block is not. One helper that
  names the production replaced seven call sites that each returned `[]`.
* `007` was accepted (an IntValue may not have a leading zero) and so was `1.`
  (a fraction needs a digit). The lexer now also refuses a number followed by a
  digit, a `.` or a name start, so `1.2.3` is an error rather than two tokens.

A harness defect came out of the same exercise: `set -e` plus a crashing subject
made the script stop mid-run having printed **no verdict**, hiding every later
section. The subject now runs through a helper that never aborts and names the
section it failed in. `set -e` stays for the preflight, where a missing oracle
should stop everything.

Type-system **extensions** (`extend ...`) are refused rather than mis-parsed —
reading `extend type T` as `type T` would produce a tree that says something the
document did not — and the refusal is *asserted*, so the day extensions land that
section fails and says the assertion is stale.

**HTTP/2 frames** — the preface, the 9-byte header, SETTINGS / WINDOW_UPDATE /
RST_STREAM / GOAWAY payloads, and the gRPC message prefix. `hyperframe` is the
oracle: 50 frames byte-identical on encode, the same 50 compared on *fields* on
decode, with the sweep crossing type × flags × stream id × payload size (0, 1, 2,
255, 256, 16383, 16384 — every length-encoding boundary).

One byte has **two independent confirmations**, which is the only kind of
agreement worth having: an empty SETTINGS frame serialises as
`000000040000000000`, and that is byte-for-byte what `grpcurl` 1.8.8 was observed
sending on a real connection. hyperframe and grpcurl never met.

Poisoning that gate found two things the sweep could not reach:

* **The `lshr` mask was dead.** Every shift here is immediately masked with 255 to
  extract a byte, and the bits an arithmetic shift copies in sit above bit 7, so a
  logical shift gives the same answer. Removing the mask changed nothing, which is
  the definition of dead code. It is *not* dead in `contrib/proto`, where the
  shifted value is the loop variable and a negative int64 would never terminate —
  the contrast is now written down in both files.
* **The writer's stream-id mask was never exercised**, because every stream id in
  the sweep already has the reserved bit clear. A section now writes `0x80000001`
  and requires the same frame as stream 1. The decode direction was already
  covered: `0x80000001` must read as 1, not 2147483649.

Both are the same shape — a guard nothing reaches is indistinguishable from a
guard that is wrong.

## 2026-08-18 — Two protocols: the protobuf wire format, and GraphQL documents

_`contrib/proto` and `contrib/graphql`, each with a gate against somebody else's
implementation._

**`contrib/proto/wire.mere`** — the Protocol Buffers wire format, both
directions, below any schema. `scripts/proto_parity.sh` holds it to **protoc's
bytes**: one message containing every wire type compared whole, swept value lists
crossing every varint length boundary, the int64 edges, and protoc's own bytes
read back and rewritten. Interpreter and C backend both.

Three things the harness had to be taught, each by being wrong first:

* **`bit_shr` is arithmetic**, so a negative int64 shifted right never reaches
  zero and the encoder loops forever. Every right shift here is masked.
* **0 cannot be swept.** proto3 omits a scalar holding its default, so
  `protoc --encode` answers the empty string for `v: 0` while a schema-less layer
  writes `0800`. That is a question one layer up, not a wire-format disagreement.
* **The zigzag bound is half the varint bound**, because zigzag doubles its input.

And one thing that is pinned rather than fixed: **the interpreter's int is
63-bit** (OCaml's native int) while every compiled backend's is 64-bit, so above
2^62 the same program gives different answers — `bit_shl 1 62` is negative on the
interpreter and `bit_shl 1 63` is zero. Those are recorded as a DIVERGE pin, not
a tolerance, so the day the interpreter becomes 64-bit that section fails and
says the pin must be retired. Related: an integer literal above 2^62−1 cannot be
written at all — it dies with an uncaught `Failure("int_of_string")` — so the edge
values in the harness are computed from 2^62−1 instead. This is the int axis of
the open question about builtin parity at particular values, and it is the same
shape as the float axis before exponent literals landed in v0.1.260: the reason
it was not measured is that it could not be written.

**`contrib/graphql`** — lexer, parser and printer for executable documents
(operations and fragments; SDL is a separate grammar and is not here).
`scripts/graphql_parity.sh` checks it against graphql-js by sending our output
back through their parser:

```
theirs: print(parse(D)) -> A     ours: print(parse(ours(D))) -> B     assert A == B
```

`print` is a function of the AST alone, so equality holds exactly when the parses
agree — **and nothing transcribes an AST**. The alternative, serialising both
trees into a shared format, needs a serialiser for the oracle's tree that can hold
the same misreading as the parser it checks; a differential gate that shares a bug
with its subject reports agreement. The corpus is derived rather than written
down: every value kind × every position admitting a value, every selection form,
every operation shape, nested type expressions. 153 documents.

**The gate was then deliberately broken to see whether it could fail.** Dropping
every directive in the printer: caught. Dropping field aliases in the parser:
caught. Making the lexer call **every** number an `IntValue`: **not caught** — the
printer emits a numeric literal's lexeme unchanged, so `IntValue "1.0"` prints
`1.0`, the oracle re-parses it as a `FloatValue`, and the two printed documents
agree. A round-trip is blind to any distinction that prints identically. A fourth
section now asks for the kind directly, and it is the one place that transcribes
anything from the oracle's tree — a two-word vocabulary.

The printer **refuses** a block string whose value would not survive re-parsing
rather than emitting an ordinary string: the dedent rule is applied again on the
way back in, and downgrading it would round-trip the text while losing
`block: true` from the tree — a wrong answer wearing the face of a parser bug.

Both gates are in CI, both run under `dash` before being put there, and both
oracles are pinned and printed (protoc 27.3, graphql-js 17.0.2).

## v0.1.279 — 2026-08-17

_The refusals that were left, and three bugs they walked into._

The enumeration's tail: `bytebuf_get` / `bytebuf_set`, `write_file_bytes`'s byte
range, `len` on a value that is not a list, and comparing two functions. Asking
them turned up three things that were not about refusals at all.

**A program that used a ByteBuf and no `bytes` value did not compile.** The C
backend emits the `bytes` runtime when `bytes_used` is set, and freezing a
ByteBuf calls `__lang_bytes_alloc` — the comment above the emit even says so, so
the *order* of the two runtimes had been thought about and the *dependency* had
not. Third time a use-gate has emitted a call to a function it did not emit.

**`len (Some 1)` emitted C that dereferenced `payload.Cons` on an option.** The
guard for the cons-walking branch asked whether the *program* contained `Nil` and
`Cons` anywhere, not whether *this type* has them, so any program that also
mentioned a list took that branch for every polymorphic variant. It asks the
type now, and a type with no length is a clean codegen refusal naming the
alternatives.

**Comparing two functions was a runtime failure on the interpreter and invalid C
on the compiled backends** — `==` between two closure structs does not compile.
The type is known where the comparison is written, so the typer answers there
now, with the interpreter's own words.

The refusals themselves: ByteBuf's index failures and the byte-range check both
printed and called `exit(1)`, so `try_or` could not take them and the program
stopped where the interpreter carried on. They are catchable failures now, with
the messages they already had. `test/parity/bytebuf_edges.mere` is the gate —
interp + C, since bytes/ByteBuf is those two backends by scope.

Also: `__lang_str_count` still returned `i32` on LLVM after v0.1.276 widened it
on C and Wasm — a count past two billion came back negative. The sweep missed
exactly one backend of the three.

---

## v0.1.278 — 2026-08-17

_The last of the oracle's refusals._

The `bytes` value has the same index surface as `vec`, and it had all the same
problems one slice later than `vec` did:

| | before | after |
|---|---|---|
| C, LLVM | `abort()` — exit 134, and nothing `try_or` could catch | the interpreter's catchable failure |
| Wasm `bytes_get` | trapped with no message, after truncating the index to 32 bits | checked at full width, and it says what happened |
| Wasm `bytes_slice` | **no range check at all** — copied from wherever the arithmetic pointed | refused |

`random_int` on the Wasm host accepted any bound. There is no RNG wired there
yet, which is a documented limitation — but *"no RNG here"* and *"any bound is
fine"* are different statements, and the second one is a wrong answer. The bound
is checked now even though the value it returns is still a deterministic zero.

That closes the enumeration started in v0.1.276: every refusal the interpreter
raises is now raised by all four backends, with the same words, catchable in the
same way. `test/parity/refusals.mere` covers the caught side and there are 15
programs in `test/parity/fail/`.

---

## v0.1.277 — 2026-08-17

_Finishing the enumeration, and two things it turned up on the way._

v0.1.276 asked the oracle's refusals and fixed the nine it had probed. This is
the rest of that list.

**`bool_of_str`** answered `false` for anything that was not `"true"` — on all
three compiled backends, with a comment in the C source stating that this
"matches interp". The interpreter has never done it: it refuses any word that is
not one of the two. A claim in a comment is not a check.

**`float_of_str`** was three different wrong answers to the same program:

| input | interp | C / LLVM (atof) | Wasm (parseFloat) |
|---|---|---|---|
| `"abc"` | refuses | `0.0` | `nan` |
| `"1.5x"` | refuses | `1.5` | `1.5` |
| `"1_000.5"` | `1000.5` | `1000.5` | **`1.0`** |
| `"inf"` | `inf` | `inf` | **`nan`** |
| `"0x1p3"` | `8.0` | `8.0` | **`0.0`** |
| `""` | refuses | refuses | `nan` |

`atof` reads a *prefix* and has no way to say "that was not a number"; on Wasm
the host's `parseFloat` has the same problem plus a smaller idea of what a float
is, and its failure value is `NaN` — which is indistinguishable from the float
`nan`, so nothing could be refused there at all. Validity now comes back from the
host separately, because one return value cannot say both.

The oracle is `float_of_string (String.trim s)`, which accepts rather more than a
decimal point: hex floats, `inf` / `infinity` / `nan` in any case, signs, and
underscores as separators (`1__0.5` is 10.5). All four backends now agree across
all of it, and `test/parity/refusals.mere` checks fourteen spellings.

**Two things the new gate found on its way in:**

- `str_unescape` allocated its buffer for the *input's* length, and every escape
  makes the output shorter — so the length header said the wrong thing, and
  `str_len (str_unescape "a\nb")` was 4 on C and LLVM where the interpreter and
  Wasm said 3. Printing the value wrote a trailing NUL, which is invisible in a
  terminal. It took a case that printed an unescaped string to see it.
- The Wasm host's *worker* env is a second import table for the same module, and
  adding an import to the module without adding it there makes instantiation
  throw inside the worker — after which the main thread waits on a generator that
  will never yield. That is a hang, not an error: it cost twenty minutes of a
  parity run before I looked at the process list.

---

## v0.1.276 — 2026-08-17

_Asking the question mechanically, after finding the same shape by accident twice._

v0.1.274 found string sizes narrowed to 32 bits; v0.1.275 found indices narrowed
the same way, one layer down. Both were found by a probe that happened to ask.
So the third time the question was asked from the other end: **every refusal the
interpreter can raise**, enumerated from `eval.ml`, checked against what the
compiled backends do with the same input.

Nine diverged, and always in the same direction — the compiled backends had no
check at all and returned whatever the byte or pointer arithmetic produced:

| input | interp | C / LLVM / Wasm (before) |
|---|---|---|
| `chr 256` | refuses | a NUL — the cast to `unsigned char` *was* the domain check |
| `chr (0-1)` | refuses | `0xFF` |
| `chr (2^32+65)` | refuses | `"A"` |
| `ord ""` | refuses | `0` (it read byte 0 whatever the length was) |
| `ord "ab"` | refuses | `97` |
| `str_repeat s (0-1)` | refuses | `""` |
| `str_unescape "a\q"` | refuses | `"aq"` — an undefined escape became the letter |
| `owned_vec_get v 5` | refuses | `abort()`, which `try_or` cannot catch |

Every one is a value a program can produce by accident and then keep computing
with. All four backends now raise the interpreter's own failure, with its exact
words: `chr: 256 out of byte range [0, 255]`, `ord: expected single-char str, got
length 2`, `str_repeat: negative count -1`, `str_unescape: unknown escape '\q'`.
`test/parity/refusals.mere` is the caught side; `uncaught_chr_range` and
`uncaught_ord_length` join the uncaught ones.

The same sweep turned up three more narrowings and closed them: `str_count`'s
result, `strbuf_len`'s result, and `sleep_ms`'s argument were all `int`.

A note on method: the harness for the first measurement had a bug of exactly the
kind these slices keep finding — when a backend failed to compile, the shell
variable kept the *previous* backend's output, so one column of the table was a
copy of another. It was caught because `random_int` has no LLVM lowering and the
"LLVM" column reported values anyway. A measurement that cannot fail loudly is
not a measurement.

---

## v0.1.275 — 2026-08-17

_An index the collection does not have — answered, for years, with an element._

```
let v = vec_new ();
let _ = vec_push v 10;
let _ = vec_push v 20;
vec_get v 4294967297     // interp: refuses.  C, LLVM, Wasm: 20.
```

An index is a Mere int, sixty-four bits of it, and every compiled runtime took
one as thirty-two. The bounds check then ran on the truncated value, so
4294967297 was checked as 1 and a two-element vec cheerfully returned its second
element and exited 0. All three compiled backends agreed with each other, and
none of them agreed with the interpreter. No test caught it because every index
in every test was small — the same blind spot the string widths had in v0.1.274,
one layer down.

Out of range was its own mess, three ways at once:

| | before | after |
|---|---|---|
| interp | catchable failure naming index and length | unchanged — it was the oracle |
| C | `fprintf` + `abort()`: exit 134, and nothing `try_or` could catch | the interpreter's failure |
| LLVM | `abort()`, no message | same |
| Wasm | `unreachable`: a trap, no message | same |
| `char_at` / `substring`, all three | read past the end and returned what was there | same |

Every backend now raises the interpreter's own failure, which names both numbers
at full width: `vec_get: index 4294967297 out of bounds (len = 2)`. On C and LLVM
the message is built with `snprintf` — LLVM's needed its varargs signature spelled
out at the call site, or the arguments arrive through the wrong ABI slots and the
message prints numbers nobody passed. Wasm has no `snprintf`, so it builds the
sentence from interned parts with its own `show_int` and `str_concat`.

`test/parity/index_edges.mere` is the caught side (nineteen positions, in range,
one past the end, negative, backwards, and past what 32 bits can name);
`uncaught_vec_index`, `uncaught_char_at_index` and `uncaught_substring_range` are
the uncaught side.

**What it found immediately.** The Ruby subset's `utf8_cp` decodes a sequence's
continuation bytes before checking they exist, and on binary data — where any byte
≥ 0xC0 looks like a lead byte — the last one sends it past the end of the buffer.
It had been reading out of bounds on every `SHA-1` call for as long as digest has
existed, and nothing showed: the read returned the NUL terminator and the value
was discarded, since only the sequence *length* is used. A check that refuses is
how a read like that stops being invisible.

---

## v0.1.274 — 2026-08-16

_A string the machine cannot hold, and two backends that answered with a number._

Asking for `str_repeat "ab" 500000000000000` used to produce four different
things, and the two most used backends produced a **plausible integer and exit 0**:

| | before | after |
|---|---|---|
| interp | `Fatal error: exception Out of memory`, exit 2 | `out of memory`, exit 1 |
| C | `-1530494976`, exit 0 | `out of memory`, exit 1 |
| LLVM | `2764472320`, exit 0 | `out of memory`, exit 1 |
| Wasm | *(no output)*, exit 1 | `out of memory`, exit 1 |

Two defects compounded to make that possible.

**Mere's int is 64-bit; the runtimes serving it were not.** The count reached C
through an `int` parameter and LLVM through an explicit `trunc i64 ... to i32`, so
a 64-bit value arrived as its low 32 bits and asked for a string the program could
actually have — a *different string*, returned without complaint. The same
narrowing was in `str_len` (`(int) __lang_str_size`), `substring`'s indices,
`str_index_of`'s result and `utf8_len`'s count. A 2.15GB string — one byte of
address past what a 32-bit offset can name — reported a **negative length** and a
**negative match offset**. Every string in every test until now was small, so the
axis had never been asked.

**The allocator never read what malloc answered.** When it said no, the next line
wrote through the null it returned, and the program died by segfault — the
nameless death v0.1.271 removed everywhere else. It is a named, catchable failure
now, on both backends, and the region's doubling no longer wraps `size_t` on its
way to a request bigger than half the address space.

On Wasm the memory is a fixed 64MB and nothing grows it, so exhaustion arrives as
an out-of-bounds trap. The host used to exit 1 in silence for every trap that was
not `fail`; it now names that one *out of memory* and prints the engine's own words
for anything else, so no trap is anonymous.

Gated two ways. `test/parity/fail/uncaught_out_of_memory.mere` holds all four
backends to the same sentence on a request no allocator can satisfy — it is refused
instantly, so it costs nothing. `scripts/bigstr_check.sh` is the 2.15GB
measurement, deliberately *not* in the parity run: it costs 4.3GB of resident
memory per backend, and a gate too expensive to run is one people stop running.
The Wasm backend is not in it, because a 2GB string is not a value that backend can
hold — asking it would measure the memory limit rather than the width.

---

## v0.1.273 — 2026-08-16

_A gate that cached the thing it was testing._

`scripts/selfhost_check.sh` compiles a set of programs with both compilers -- the
OCaml one and the self-hosted Mere-in-Mere one -- and diffs what the two binaries
print. Run yesterday it reported **7 failures out of 7**, every case, with the
self-host side empty: the reading a person would take from that is that the
self-hosted compiler is completely broken.

It was fine. The gate builds the self-hosted compiler into `/tmp/selfmere.wasm`
*only if that file does not already exist*, and the copy sitting there was three
days and one ABI change old -- built before `str` grew its length header. The gate
was testing a compiler nobody had asked about.

CI never disagreed. A fresh runner starts with an empty `/tmp`, so CI always built
the current compiler and always passed. **The same commit was green on the machine
nobody looks at and red on the machine someone is working on**, and the red one was
the wrong answer.

It builds every run now. The whole build is 260ms -- there was never enough here to
cache. A sweep of the other gates for the same shape (reuse an artifact if present)
finds none.

The failure report is also bounded now. When this failed it wrote 18MB of WAT into
the terminal, and the part worth reading -- that one side was empty -- was the first
line of it. Ten lines of each side and the paths, so the rest is one command away.

---

## v0.1.272 — 2026-08-16

_Q-032 closed: the Wasm backend learned to unwind, and the last pin came down._

`fail` on this backend has nothing to unwind with. It sets a flag, returns a
sentinel, and the `try_or` at the boundary reads the flag -- so the failure was
caught, but **everything between the fail and the catch still ran**. A body that
pushed three strings and failed after the second pushed the third here and
nowhere else. That one line was the parity suite's last DIVERGE pin, standing
since v0.1.246.

Unwinding, written out by hand: after a call, ask whether the callee failed and
return at once if it did. The check goes in at `emit_instr` -- the one place every
call passes through -- rather than at each emission site, which is how the sites
that were forgotten in earlier sweeps would have been forgotten again. A
`return_call` is exempt: it is a tail call, the frame is already gone. So is
`try_or`'s own call to the thunk, which is the frame that must *not* propagate.

The interesting half is the second question: **which calls need to ask**. A callee
that cannot reach `$__lang_fail` cannot have set the flag, and the assembled module
can prove that where the emitter could not -- so a pass over the finished module
computes reachability and takes those checks back out. On a self-hosted compile
that is 2,524 of 3,722 call sites:

| | module | vs no unwinding |
|---|---|---|
| no unwinding (before) | 241,915 B | — |
| a check after every call | 275,273 B | +13.8% |
| dead checks pruned | 253,067 B | **+4.6%** |

Everything unknowable keeps its check: indirect calls (the callee is a table
index), imported functions (the host can re-enter the module), and any callee
without a definition in the module. Removing a needed check would be a silent
wrong answer, so every doubt resolves toward keeping it.

`scripts/parity.sh` also learned to fail on a **stale pin**. A pinned divergence
that starts matching used to pass quietly, because a matching case never reads
its `.expected` file -- the declaration would have stayed on disk saying something
that had stopped being true. That is the exact failure the pin mechanism exists to
prevent, so the gate now names the file and asks for it to be deleted. It is how
this slice found out it was done.

---

## v0.1.271 — 2026-08-16

_The failure that had no name._

Recursion deeper than the stack is the most common way a Mere program actually
dies -- three of this week's findings were exactly that -- and until this slice it
was the one failure the language never said anything about. Four backends gave
four answers, and the two most used gave none:

| | before | after |
|---|---|---|
| interp | `Fatal error: exception Stack overflow`, exit 2 | `stack overflow (recursion too deep)`, exit 1 |
| C | *(nothing)*, exit 139 | same sentence, exit 1 |
| LLVM | *(nothing)*, exit 139 | same sentence, exit 1 |
| Wasm | node's `RangeError` + hundreds of trace frames, exit 1 | same sentence, exit 1 |

The compiled backends carry a `SIGSEGV`/`SIGBUS` handler that runs **on a stack of
its own** -- the stack that just overflowed has no room left to run a handler --
and it claims a stack overflow only when the faulting address is *near the stack*.
Anything else keeps its own name: a segfault from some other cause is still
reported as a segfault, because a diagnostic that guesses is worse than one that
does not exist. The bounds are read from the thread rather than assumed, which is
what makes the answer right for a program linked with a bigger stack -- a 512MB
one, as the Ruby subset uses, overflows far below any 8MB guess and would
otherwise have been misnamed.

The interpreter's limit is **declared, not discovered**. OCaml 5 grows the main
fibre's stack by copying it, so finding the host's real ceiling costs 68 seconds
and gigabytes of copying, and the depth it finds -- around forty million frames --
is two orders of magnitude past anything a compiled backend can reach. A program
that recurses that far has already failed everywhere else. The interpreter now
stops at 1,000,000 frames (`MERE_MAX_DEPTH` to move it) and says the same sentence
in about a second. The count comes back down with the stack it was counting, so a
program that catches a failure inside a loop does not drift upward into a depth it
is not at.

`test/parity/fail/uncaught_stack_overflow.mere` is where the agreement is checked
rather than claimed: 8 failing-program cases now, all four backends matching on
exit status, prior output and message.

This also corrects v0.1.270's closing paragraph, which named the region as the
cause of a crash nobody had measured. It was the stack.

---

## v0.1.270 — 2026-08-16

_The other helper that could not survive a long list, and a sweep that says there is
no third._

`list_filter` was fixed two slices ago for rebuilding its result through the return
path. The obvious next question is whether it was the only one, and asking it the
lazy way — grep the prelude for a self-call wrapped in a constructor — turns up
exactly one more: **`list_sort_insert`**, which walks to the insertion point through
`Cons (h, list_sort_insert cmp t x)` and so recurses once per element it passes.
Inserting into a 50,000-long sorted list overflowed the stack on the compiled
backends.

It accumulates and reverses now. The same sweep over the whole prelude afterwards
finds no remaining wrapped self-call: `list_map`, `take`, `concat`, `flat_map`,
`zip`, `append`, the merge-sort quartet and the utf8 helpers were all already in
that shape, and the two that were not are both fixed.

Worth separating from the depth question: each list helper handles a 50,000-element
list on its own, and a program that builds *several* such lists at once stops
earlier on the compiled backends. That is the region running out, not the stack --
a different axis, and one this measurement deliberately does not mix in.

> **Corrected in v0.1.271.** That last paragraph is a guess written as a finding:
> the crash was never measured, only named. It is the stack. The same program
> runs to completion under `ulimit -s 65520`, and under v0.1.271 it says so
> itself. The region was not involved.

---

## v0.1.269 — 2026-08-16

_A `match` arm is a tail position too, which is where nearly every recursive list
helper's tail call actually lives._

v0.1.267 gave the LLVM backend a notion of tail position and emitted `musttail`,
and the measurement that immediately followed it — the collection value axis — said
`list_sum` over a list still died at 100,000 there while C was fine at 200,000. The
reason was narrow: **only `If` had been made tail-aware.** Every recursive helper in
the prelude is written with `match`, so its tail call sat in an arm that branched to
a join and phi'd — the one shape `musttail` cannot take.

An arm in tail position returns now, exactly as a tail-position `If` branch does.
`list_sum` runs at 500,000 on LLVM, and a program that puts a 300,000-element list
through every list helper — len, sum, rev, map, filter, fold — gives the same
answers on the interpreter, C and LLVM.

The lesson is about where the measurement pointed. "Tail position" sounded like one
concept and was implemented as one construct; the gate written an hour later found
the other construct by asking a question that had nothing to do with tail calls.

---

## v0.1.268 — 2026-08-16

_A missing map key is catchable everywhere, and `list_filter` survives a list longer
than the stack._

The third value-axis parity case — after the integer widths and the string edges —
asks about collections: the empty ones, the single-element ones, a key that is not
there, and a list long enough to leave the small cases behind. It found two.

**A missing map key was not catchable on any compiled backend.** `map_get` wrote its
own diagnostic and then `abort()`ed (C, LLVM) or executed `unreachable` (Wasm), so
`try_or (fn () -> map_get m k) d` answered `d` on the interpreter and died with 134
or 1 everywhere else. It goes through the same failure path every other `fail` uses
now: caught, it returns the default; uncaught, all four print the same sentence and
exit 1.

**`list_filter` recursed to the length of the list.** Every other list helper in the
prelude accumulates and reverses — `list_map`, `list_take`, `list_concat`,
`list_zip`, `list_append` all do — and this one built `Cons (h, list_filter t p)`, so
filtering 100,000 elements overflowed the stack on a backend where mapping them did
not. It accumulates now.

The case is sized at thirty thousand deliberately. Past that the axis stops being
about values and becomes about stack depth, which differs per backend and per
operation — `list_sum` alone survives 80,000 on LLVM and dies at 100,000 while C is
fine at 200,000. A value gate that also measured the stack would report the wrong
thing whenever either moved.

---

## v0.1.267 — 2026-08-16

_The LLVM backend's tail calls are `musttail`, so a loop written as recursion runs
in constant stack there too._

The C backend learned this in v0.1.230 — self tail calls became a `goto` — and the
same measurement was left standing against LLVM: **ten million iterations died with
SIGSEGV at `-O0`** while C ran them in constant space, and the emitted IR carried no
tail marker at all. The note recorded it as measured rather than assumed, and said
what the fix would cost: `musttail` is the marker LLVM guarantees regardless of
optimisation level, but it requires the call to be **immediately followed by a `ret`
of its result**, and this backend had no notion of tail position.

It has one now. `emit_expr` carries the same tail-position flag the C backend uses,
cleared at entry and restored only for the sub-expression that stays in tail
position. An `If` in tail position **returns from each branch** instead of joining
through a phi, which is what puts a tail call next to its `ret`. A call in tail
position whose prototype matches the enclosing function's is emitted as `musttail`.

Ten million iterations now run at `-O0`, and so does mutual recursion between two
functions. `MERE_NO_TAIL_CALL=1` turns the transform off, the same escape hatch
`MERE_NO_TAIL_LOOP` gives the C side — "is it this change?" stays a one-variable
question.

---

## v0.1.266 — 2026-08-16

_The string values four backends were never asked about, and the two answers that
were wrong._

A new parity case walks the axes the open question about builtin parity names next
to the width one it already closed: the empty string, an index that is not inside
the string, and a string big enough to leave the small cases behind. Every string
probe in the suite until now used a literal a human types in the middle of the
range, so a helper that divides by a length of zero, or reads one byte past the
end, answered every question it was asked.

It found two, both on LLVM and both from this week's header migration:

- **`str_repeat s 0`** allocated its empty result directly, without a header — the
  one case that computes no length, and so the one the mechanical conversion
  missed. `str_len` of it read whatever preceded the allocation.
- **`str_trim`** walked a pointer into the string and then asked for *its* length.
  An interior pointer has no header of its own. This is the same bug the Wasm
  backend had in v0.1.262 — invisible on LLVM until today, because there was no
  header there to read wrongly.

The second one is the interesting one: the same defect existed in two backends,
written years apart, and the gate that found the first could not see the second
until the representation changed underneath it.

---

## v0.1.265 — 2026-08-16

_What `fail` hands back on Wasm is an empty str, so the code it cannot unwind past
survives to reach the `try_or`._

Wasm has no unwinding here: `fail` sets a flag and returns, and the callers check
the flag on the way out. The value it returned was 0 — which is not an address. A
consumer sitting between the fail and the `try_or` that treated it as a str read
the length header at -4 and trapped, so `try_or (fn () -> str_len (fail "b")) (-1)`
**died with no output** where the interpreter, C and LLVM all answered -1. Which of
the two happened depended on what the consumer did with the value, which is the
worst property a failure can have.

The sentinel is an interned empty str now. An empty str is a valid answer to every
string operation, so the code between the fail and the catch survives, and the
`try_or` default comes back on all four backends.

This does not make `fail` unwind, and the parity case still pins the difference
that remains: statements after a `fail` in the same body still run, so a buffer
that three pushes wrote to reads "onetwothree" there and "onetwo" everywhere else.
That is the open half of the question, and it is where the pin now points.

---

## v0.1.264 — 2026-08-16

_The LLVM backend's `str` carries its length, and the last pin comes off._

Its str was a bare pointer: `str_len` called `strlen`, `==` called `strcmp`, and
literals were plain `[N x i8]` globals. So on that backend a zero byte was not a
byte — `str_len (chr 0)` answered 0 against 1 everywhere else, and `chr 0 == ""`
was true. The open question about it named the consumers: percent-decoding a URL
and decoding Shift_JIS both produce arbitrary bytes, and LLVM alone gave a
different answer for them.

It now lays a str out the way the other three do — `[i64 len][bytes][NUL]`, value
at byte0. Literals are `{ i64, [N x i8] }` constants and the value is a constant
getelementptr into the second field; every runtime helper that builds a string
allocates through `__lang_str_alloc`; the ones that only learn their length at the
end (replace, trim, unescape) call `__lang_str_finish` to write it. Strings that
arrive from libc — `asprintf` for show, `snprintf` for floats — are copied into a
header by `__lang_str_of_cstr` at the boundary. `str_len`, `==`, `str_compare` and
`print` all read the header, so a NUL is a byte on all four backends.

The trailing NUL stays. Everything else in this runtime still hands pointers to
libc, and keeping the terminator is what let the migration be incremental rather
than a rewrite.

Two things repeated from the Wasm slice a day earlier, which is worth writing down:
the allocator had to be emitted **unconditionally** (it lived with the concat
helper, so a program that only showed a value referred to a function that was not
there), and every internal message global that gets concatenated — the fail prefix,
the int_of_str message, the show constants — needed a header of its own.

`nul_in_str` has no pinned divergence left.

---

## v0.1.263 — 2026-08-16

_The self-hosted Wasm backend carries the length header too, so the host can stop
guessing._

The previous slice found that `print` on Wasm wrote up to the first NUL and could not
do otherwise: the JS host runs modules from **both** compilers, and while the OCaml
backend lays a str out as `[i32 len][bytes][NUL]`, the self-hosted one still emitted
the pre-header representation — a bare NUL-terminated buffer — while stamping the
same ABI number as the compiler that carries a header. A number that says "you may
read the length at ptr-4" is worth nothing if half the modules do not have one.

So the self-hosted backend lays strings out the same way now: literals carry a
four-byte header in the data section, `$__lang_strlen` reads it instead of scanning,
and every helper that builds a string — concat, substring, repeat, char_at, chr,
strbuf_to_str, unescape, show_int/bool/str — allocates through one place that writes
it. The digit buffer `show_int` fills right-to-left is copied into a str that has
room for a header in front, the same answer the OCaml backend reached.

With both compilers agreeing, the host reads by length, and `print` on Wasm writes
the whole value: the `nul_in_str` parity case needed a Wasm pin for exactly one
slice. LLVM keeps its pin — its str is a bare pointer with no header anywhere.

Two things fell out of doing it. `$__lang_str_alloc` had to be emitted
unconditionally rather than with the length helper: a module that showed a bool
without measuring a string referred to a function it did not define. And the emitted
module grew 17 bytes, which the size guard on the self-hosted codegen reports —
four bytes per literal is the cost of a length that does not have to be searched for.

---

## v0.1.262 — 2026-08-15

_An interior pointer has no header, and `str_trim` asked one for its length._

Chasing the Wasm half of the previous slice found something smaller and real.
`str_trim` skips leading whitespace by walking a pointer INTO the string, and then
called `$__lang_strlen` on that pointer to find out how much was left. The length of
a Mere str lives in a header immediately before byte0 — so for an interior pointer
that read takes **the string's own bytes as a length**. It is bounded by a NUL scan
on the other backends, which is why only Wasm blew up on it, and why
`str_len (str_trim s)` was the shape that showed it rather than `print (str_trim s)`.

It takes the original length once now, uses it to bound the skip, and subtracts what
the skip consumed. A NUL inside the value stays a byte through `str_trim`, on all
four backends.

The Wasm host still writes up to the first NUL, and the reason turned out to be
sharper than "something overstates its length": **the self-hosted Wasm backend emits
the pre-header string representation** — its `$__lang_strlen` scans for a NUL and its
strings carry no header — while stamping the same ABI number as the compiler that
does. The host is shared between both kinds of module, so it cannot trust the header
until the self-hosted backend carries one, or stops claiming the ABI that says it
does. That is written down where the parity case pins it.

---

## v0.1.261 — 2026-08-15

_`print` writes the string's length, and the two backends that cannot are pinned._

`str` became byte-safe in the v0.1.129 arc: the length lives in a header rather than
in a terminator, and `str_len (chr 0 ++ "X")` has answered 2 ever since. `print` did
not — it went out through `puts`, which stops at the first NUL — so the same value
measured 2 and printed one character. **Two answers about one value is a bug, not a
choice**, which is what the open question about this asked to settle.

The C backend writes by length now (`print`, `print_err`, `print_no_nl`), and matches
the interpreter byte for byte.

The other two are pinned rather than fixed, each for its own reason, in a new parity
case that prints NUL-carrying strings as well as measuring them:

- **LLVM** has no length header at all — its `str` is a bare pointer, and
  `str_len (chr 0)` is 0 there against 1 everywhere else. The NUL is not truncated
  on output; it was never in the value.
- **Wasm** has the header and `str_len` reads it, but the JS host writes what it
  finds up to the first NUL. Making the host trust the header instead surfaced a
  second thing: one `str` on the self-hosted compiler's path arrives with a header
  that overstates its content by half a megabyte of zeros. Until that is understood
  the host keeps scanning, and the pinned case is where it will be noticed.

Pinning is the point. Dropping U+0000 from the case — which is what happened the
first time this came up — would have made the file agree by not asking.

---

## v0.1.260 — 2026-08-15

_Exponent notation, because the ends of the double range could not be written down._

`1.7976931348623157e308` lexed as the float `1.7976931348623157` applied to a variable
named `e308`. A probe that needed the largest finite double, the smallest normal and
the smallest subnormal had to **build all three out of powers of two** — scaling by
halves until the value stopped changing — rather than write them.

Now a literal with an exponent is a float, with or without a decimal point: `1e3`,
`2.0e-3`, `4E+5`. A digit has to follow the `e` (after an optional sign), so `1.5 e`
is still a float applied to a variable called `e`, which is the only thing this could
have taken away.

The formatter had to change with it. `string_of_float` keeps 12 significant digits,
which was enough for every literal that could be written before and is not enough
now: formatting `1.7976931348623157e308` would have written a *different number*
back. It emits the shortest form that reads back as the same double.

And then the notation paid for itself immediately. A new parity case walks the float
values four backends had never been asked about — the ends of the range, the
subnormals below the smallest normal, both zeros, NaN — none of which could be
*reached* before, because every float literal in the suite was one a human types.
It found a real divergence on the first run: **`nan < 0.0` was true on the
interpreter and false on all three compiled backends.** The interpreter routed every
ordered comparison through OCaml's total `compare`, which sorts NaN below
everything; the operator is IEEE, where every ordered comparison with NaN is false.
Sorting still uses the total order — that part was deliberate — but `<` on two
floats is now the float comparison, and the four backends agree.

---

## v0.1.257 — 2026-08-14

_The tokenizer switches its own state after a start tag, which is a shortcut with a
stated boundary rather than a guess._

`<title>t</title>` used to tokenize as a start tag, a bare `t`, and an end tag,
because the content of a title is RCDATA and **the standard has the tree builder
decide that**. A tokenizer handed a whole document cannot ask.

For HTML the decision is a pure function of the tag name, so the tokenizer makes it:
title and textarea go to RCDATA, style and its relatives to RAWTEXT, script to script
data, plaintext to PLAINTEXT. **The exception is foreign content** — `<title>` inside
SVG is an ordinary element — and until this backend knows about foreign content the
two answers are the same. That is why this is a shortcut and not a mistake: the
boundary is known and written down where it is taken.

The conformance suite still passes 1,900 of 1,900, and the browser dogfood's tree
construction went from 83 of 189 to 88.

---

## v0.1.256 — 2026-08-14

_All 228 labels the Encoding Standard defines, generated, replacing a hand-written
list of the four this directory can decode._

The previous slice added `utf-16` to that list. This is the same gap at its full
size: a page declaring `iso-8859-2` read as a page declaring **nothing at all**,
because the list only had labels for encodings there is a decoder for.

**Those are two different questions.** `label_of` answers what a label names;
whether this directory can decode the result is what `decode` answers, and it
already answers `None`. Conflating them made the absence of a decoder look like the
absence of a declaration, which the HTML standard treats differently — it is the
difference between "use the default" and "use the encoding the page named".

The table is generated from `encodings.json` and carried the way the Unicode tables
and the HTML named references are (Q-028): fixed-width records in one sorted string,
binary-searched by index arithmetic. 228 labels for 40 encodings, 8,208 characters.

The comment above the old list had already written down what would happen — "it
cannot discover a label we forgot to list, and that gap is real and is recorded
rather than implied". It took a program that asks about labels rather than about
decoding to walk into it.

---

## v0.1.255 — 2026-08-14

_A label the table forgot, found by the program that asks about labels._

`label_of` had no `utf-16`, `utf-16le` or `utf-16be`. The comment above that table
already said what would happen — "it cannot discover a label we forgot to list, and
that gap is real and is recorded rather than implied" — and this is the gap, found by
the browser dogfood asking a page what encoding it claims to be in.

Listing them is right even though nothing here decodes UTF-16: `label_of` answers
"what does this label name", which is a different question from "can this directory
decode it", and `decode` already returns `None` for a name it does not implement.
Leaving them out made `<meta charset=utf-16>` look like a page with **no declaration
at all** — and the HTML standard answers that differently from a page declaring
UTF-16, which cannot be true (the declaration is written in ASCII) and reads as UTF-8.

---

## v0.1.254 — 2026-08-14

_1,900 of 1,900. The vendored tokenizer suite passes entirely, with no exemptions._

Three fixes, and two of them were the same mistake in different clothes.

**Form feed was not whitespace.** `_is_space` compared against a `\012` escape the
lexer did not read as U+000C — so the literal was four ordinary characters and form
feed silently stopped being a space character everywhere the tokenizer looked for one.
It is `chr 12` now: whether the language spells it `\f`, `\014` or `\x0c` is a question
this file does not need an opinion about, and **getting it wrong is silent**. Twelve
cases.

**The bogus-doctype state was inventing quirks mode.** It hardcoded the force-quirks
flag rather than carrying the one the token already had, so `<!DOCTYPE a PUBLIC''''`
followed by junk — a complete, correct doctype with a parse error after it — was
reported as a quirks-mode document. Reaching a recovery state does not by itself mean
the thing recovered from was fatal. **Sixty-two cases**, and the same shape as the fix
two slices ago: the recovery path was discarding what it had rather than keeping it.

**And a NUL starting an attribute name** went through unreplaced, because that one path
appended the character without the substitution every other one had. Four cases.

---

## v0.1.253 — 2026-08-14

_Character references, named and numeric: 1,807 of 1,900 becomes 1,822 — and the
last exemption bucket comes out of the harness._

**The 2,231 named references are one string of fixed-width records**, generated from
the standard's own `entities.json`, sorted, and binary-searched by index arithmetic.
That is the shape Q-028 settled for the Unicode tables, applied again: 44 characters
per record — the name space-padded to 32, then two code points as six hex digits
each. Space pads rather than NUL because a Mere `str` cannot carry a NUL through the
compiled backends, and because space sorts below every character a name uses, so the
padded order is the plain order and a short name needs no special case. 98,164
characters, and it compiles and runs on the C backend as well as the interpreter.

**Matching is longest-first**, because `&notin;` is one reference and not `&not`
followed by `in;` — a search that stopped at the first match would be a different
tokenizer. Inside an attribute value a match that did not end in `;` is left alone
when the next character is `=` or alphanumeric, because `?a&not=b` is a query string
far more often than it is a negation sign.

**And the harness lost its last exemption.** It had a bucket that excused cases
needing character references from the failure count, back when there were none. It
came out the moment they were implemented: a bucket that exists because a feature is
missing hides real failures as soon as the feature arrives. Every one of the 1,900
cases is now a pass or a failure, and the 78 remaining are named one by one.

---

## v0.1.252 — 2026-08-14

_The tokenizer's other starting states: 1,598 of 1,704 becomes 1,807 of 1,900._

**`Html.tokenize_in` takes the state to start in and the tag that opened the
element.** An element whose content model is text — `title`, `textarea`, `style`,
`script` — puts the tokenizer in RCDATA, RAWTEXT or script data, and **only the tag
that opened it can end it**. That is why the starting state is a parameter and not a
guess: the tree builder is what knows which element it is inside, and a tokenizer
that guessed would be wrong exactly where `</` appears inside a script.

The three text-like states share one shape and one implementation: character data
until `</` plus the opening tag's name plus a space, a slash or `>`. PLAINTEXT is
the degenerate case that never ends.

**And the case count went up, which is the point.** A case listed under several
initial states is several cases — the suite writes it once and means it for each.
Running only the first reported a number smaller than what was being checked, so the
harness expands them: 1,704 entries are 1,900 cases.

---

## v0.1.251 — 2026-08-14

_Three more of the tokenizer's rules: 1,505 of 1,704 becomes 1,598. Sixty-two of
those came from one line._

**Newline preprocessing** — CRLF and a lone CR both become LF before the machine
sees them. The standard puts this in a preprocessing step rather than in the states
for the reason it shows here: otherwise every state has to say it.

**U+0000 becomes U+FFFD inside markup** — names, attribute values, comments,
doctypes. It is a parse error and the character is replaced rather than dropped,
because dropping it changes how many characters a later consumer counts.

**And the one that was worth sixty-two cases: the bogus-doctype state was throwing
away what had already been parsed.** `<!DOCTYPE a PUBLIC""` followed by junk has a
public identifier that is *present and empty*; discarding the state on the way into
the recovery path reported it as *missing*, which is a different token. Recovery
paths keep what they have — that is what makes them recovery rather than restart.

---

## v0.1.250 — 2026-08-14

_An HTML tokenizer, measured against the standard's own suite from the first run:
1,505 of 1,704._

```
  contrib/html/tokenizer.mere            the state machine, with the standard's state names
  test/data/html5lib/*.test              vendored html5lib-tests (tokenizer)
  scripts/gen_html5lib_testdata.sh       how they got here (maintenance, needs network)
  scripts/html_tokenizer_conformance.sh  the gate
```

**Written as the standard writes it**: one function per named state, so a line can
be found in the specification by searching for its state. Not a regular expression
or a lookahead scanner, because the recovery rules are what make HTML parseable at
all and they are stated per state — `<`, `</`, `<!` and `<?` all have defined
behaviour when what follows them is not what it looked like, and that is where the
bugs are. Two of the first three the suite found were exactly that shape: a
repeated attribute keeping the last instead of the first, and a comment ending in a
lone dash keeping it instead of dropping it.

**The pass count is pinned exactly, not as a floor.** A floor lets a regression hide
behind a new pass. The harness prints the first ten failures in full, so what is
missing is in the output rather than only in a document — and what is not covered
yet is counted by category rather than skipped silently: character references (53),
non-Data initial states (111), U+0000 replacement (57).

The suite is vendored rather than fetched by the gate, the same decision the UCD
conformance files got: a gate that needs the network fails for reasons that have
nothing to do with the code.

**Placement**: a conformant tokenizer is a library — the same shape as `contrib/url`
and `contrib/encoding` — so it lives here. Tree construction is where a browser
starts and is not.

---

## v0.1.249 — 2026-08-14

_A window, its pixels, and its input — promoted from a probe to a capability. The
interesting part is that it can be checked without anybody looking at a screen._

```
  lib/codegen_c.ml               the SDL2 runtime, emitted when a win_* extern is declared
  contrib/window/window.mere     the typed side: window, event, show, capture, poll
  test/window/window_check.mere  draw, show, read back, compare
  scripts/window_check.sh        new gate: SDL's dummy driver, no display needed
```

**Six externs and no language feature.** `win_open` / `win_size` / `win_blit` /
`win_readback` / `win_poll` / `win_close`. Pixels cross the boundary as a flat arena
offset and everything else is an int — the contract the socket family established —
so the runtime is conditional C the way PortMidi's is, emitted only when a program
declares one of these. Build with `sdl2-config --cflags --libs`.

**`size` asks the renderer, not the window.** They are different numbers on a HiDPI
display: a 640×480 window has a 1280×960 renderer, and the pixels are in the second
one. This was recorded as friction 3 when the capability was a probe — a readback
comparison against the window's size compares against a number the pixels are not
in — so the capability returns `SDL_GetRendererOutputSize` and nothing else.

**`Window.show` composites a `canvas` with the same arithmetic as
`Canvas.to_ppm`**, so what a program puts on the screen and what it writes to a file
are the same image by construction rather than by two similar loops.

**The gate is a readback, and it needed one more thing to be evidence.** Draw a known
pattern with `contrib/raster`, show it, read the window's pixels back, compare —
3072 pixels, 0 mismatches, under SDL's `dummy` video driver, which has a software
renderer and a real event queue but no display. That runs in CI and does not open a
window on your desktop.

**But `show` writes the image into the same arena block `capture` reads back into**,
so a readback that did nothing at all would hand back exactly what was written and
every pixel would match — a gate that passes while testing nothing. `capture`
poisons the block first. Checked by making the runtime's readback a no-op: 3072 of
3072 pixels then differ.

**Not gated: that an event ever arrives.** `poll` is checked only for answering
`Nothing` on an empty queue. Delivering a real key or click needs either a display
or a way to inject one, and a test-only extern that pushes events would be checking
the scaffolding rather than the capability.

---

## v0.1.248 — 2026-08-14

_Adding the last two math builtins turned up a silent wrong answer in every LLVM program
that used floats: `f_pow 3.0 2.0` was `3.0`, because the prelude's integer `pow` had
taken libm's symbol._

```
  lib/codegen_llvm.ml          Mere top-level names are prefixed `mu_`, as C's always were
  lib/codegen_c.ml             exp / log beside sqrt
  lib/codegen_wasm.ml          the same, as host imports
  scripts/run_wasm.js + 5      __lang_exp / __lang_log; and str_of_float follows C's %g
  test/parity/exp_log.mere     new: identities within a tolerance, not digits
```

**`exp` and `log`** were the last of the family that began with `floor` / `ceil` /
`round` in v0.1.243: names in the typer's environment with a type, so a program using
them type-checked everywhere and then `mere -c` emitted a call to a symbol the C compiler
had never heard of, while LLVM and Wasm said "unbound variable". They are three lines on
each backend. MISSING 8 → 6, nocompile 10 → 8.

**Then the new test failed on LLVM, for a reason that had nothing to do with it:
`f_pow 3.0 2.0` came back `3.0`.** This backend emitted Mere top-level names into the
IR's global namespace **unprefixed**, so when the prelude grew an integer `pow` in
v0.1.245 that became `define @pow` — which is libm's symbol, and `@llvm.pow.f64` lowers
to a call to `pow`. Every `f_pow` on this backend has been calling the integer power
since. The C backend has prefixed with `mu_` since it was written; this one now does too.

Neither `internal` linkage nor renaming the intrinsic helps — both were tried and
measured. The collision is the name, and the name was in a namespace shared with the C
library: `write`, `exit`, `time`, `free` and every other libc symbol were the same
accident waiting for a program to name a function after one.

The rename is the loud kind of change: a site missed by the prefix fails at link time
with an undefined symbol rather than computing something else. Four such sites turned up
and all four were tables **keyed by the source name** — the free-variable analysis, the
lifting pass's host, the shadowing guard's position lookup, and the debug info's
`DISubprogram(name:)`, which shows in a debugger and must stay what the program calls it.
Emitted names are for the IR; source names are for everything that reasons about the
program.

**And the Wasm host printed floats by a different rule.** `str_of_float` there emulated
C's `%g` with JavaScript's `toPrecision`, which is not that rule: `%g` goes exponential
when the decimal exponent is below -4 and `toPrecision` stays decimal down to 1e-7, so
`exp -10` printed as `0.00004539992976248485` on Wasm and `4.5399929762484854e-05`
everywhere else. The host implements the actual rule now, exponent padded to two digits
as C does.

**What the test asserts, and why it is not digits.** A transcendental function is not
required to be correctly rounded by anybody: `exp -10` differs in the last bit between
libm and JavaScript, and a gate comparing the digits would be reporting the C library's
build options. So `exp_log.mere` prints exact values only where the answer is exact in
binary floating point and asserts everything else as an identity within a tolerance —
`log (exp x) = x`, `exp (2 log 3) = f_pow 3 2`, `exp (0.5 log 2) = sqrt 2`. That still
fails an `exp` that returns its argument or a `log` wired to log10, both checked by
reverting the fix and watching the gate go red.

---

## v0.1.247 — 2026-08-14

_`x / 0` was four different things, and three of them were not failures. The gate built
last slice is what made fixing it a two-line test._

```
  lib/codegen_c.ml                     __lang_idiv / __lang_imod: a checked divisor
  lib/codegen_llvm.ml                  the same, as IR functions
  lib/codegen_wasm.ml                  the same, with the message interned per program
  test/parity/fail/uncaught_div_zero   new
  test/parity/fail/uncaught_mod_zero   new
  scripts/parity.sh                    the message is the first line of stderr, not the last
```

**What it did before.** The interpreter raised `division by zero`. The C backend emitted
a bare `a / b`, which is **undefined behaviour in C**: this machine's arm64 quietly
answered 0 and the program carried on printing, while an x86-64 build of the same source
raises SIGFPE. LLVM emitted `sdiv`, undefined in IR and therefore something the optimizer
may assume never happens. Wasm trapped — a defined failure, but a silent one, with no
message at all. **A wrong answer, a crash, or a silent death, depending on the backend
and the CPU.**

All four raise now, with the interpreter's messages (`division by zero` and `modulo by
zero` — it distinguishes them, so the others do too), catchable with `try_or`. It costs a
branch per division. `INT_MIN / -1` is the other undefined case in C and IR and wraps
now, matching what the interpreter already produced.

**The `-rv` backend is the exception, and it was measured rather than assumed**: built
for QEMU's `virt` board and run there, `17 / 0` is `-1` and `17 % 0` is `17`, the RISC-V
specification's non-trapping answer. That backend targets bare metal, where there is no
stream to write a diagnostic to and no process to exit, so the platform's answer is the
answer. Making it raise would mean deciding what a machine-mode trap means for the kernel
that runs on it, which is its own piece of work.

**And the harness needed one more fix to see any of it.** Its notion of "the message" was
the *last* line of stderr, which works for a `fail` call — that carries no location and
renders on one line — and not for a failure the interpreter can point at, which renders
with `--> file:line` and the source under it. The message is the first line. A
single-sink backend is the mirror image: there the diagnostic is the *last* line of the
program's own output. Two ends, because the two files are different files.

---

## v0.1.246 — 2026-08-14

_The parity harness compared stdout, so the failure surface of the language was the one
part of it four independent implementations were never held to. No parity test used
`fail` — and that was not an oversight: none could have passed._

```
  scripts/parity.sh                   failing programs compared on exit + stdout + message; DIVERGE
  test/parity/fail/*.mere             new: five uncaught failures, four backends
  test/parity/failure_caught.mere     new: try_or over every failure kind
  lib/codegen_c.ml                    exit 1, not abort; the `fail: ` tag moves to the builtin
  lib/codegen_llvm.ml                 a stderr at last: diagnostics, print_err, print_no_nl
  lib/codegen_wasm.ml                 the tag; int_of_str names its input; print_err refuses
```

**What an uncaught failure did, before this slice.** The same program exited **1** on
two backends and **134** (SIGABRT) on two others. It wrote its diagnostic to **stderr**
on two and **stdout** on two. It tagged the message `fail: ` on three and not on the
fourth. And `int_of_str "abc"` named the offending input on two backends and said only
`int_of_str: not a valid int` on the other two — the same failing program telling you
two different things, and the version that omits the input is the one you cannot debug
from. Five differences, none of which any test could see.

All four now write one line to **stderr** and exit **1**, with the message the program
raised. LLVM's panic path had been using `puts` — a backend that *refused* `print_err`
for having no stderr lowering was writing its own diagnostic to stdout. `write(2, ...)`
was already declared for `print_bytes`; declaring it unconditionally made the panic
path correct and made `print_err` and `print_no_nl` three lines each, so both stopped
being refusals on that backend.

**The `fail: ` tag belongs to the `fail` builtin, not to the printer.** Tagging where
the diagnostic is written tagged the backend's *own* failures too, which the
interpreter does not: hence `fail: int_of_str: ...` against `int_of_str: ...`. Moving it
to the builtin makes the message comparable **verbatim**, which matters more than it
sounds — see below.

**On Wasm, `print_err` now refuses.** It wrote to the same host sink as `print`, so a
diagnostic landed in the program's own output and nothing said so. The JS host ABI has
one sink (`env.puts`); giving it a second one is a change to every host that
instantiates a module, which is a deliberate change and not a side effect of a panic
message. Nothing in the repo used `print_err`, so there was nothing to break — and a
refusal names the missing thing where a silent stdout write named nothing.

**`test/parity/fail/*.mere`** is the gate: programs that are supposed to fail, compared
on exit status, the stdout written *before* the failure, and the message. Five of them.
The harness takes only the interpreter's envelope off the message (it names the source
file it is running; a compiled binary has none) and compares the rest byte for byte.

**The first version of that comparison stripped the `fail: ` tag as well**, and it made
the harness unable to see the difference this slice had just fixed: `boom` and
`fail: boom` both normalized to `boom`, so removing the fix still passed. The control
experiment caught it — revert a fix, confirm the gate goes red. **A normalization is a
place a gate stops looking**, and the fix was to make the thing consistent by
construction instead of normalizing it away.

**And a DIVERGE state, because the caught-failure test found a live one.** `fail` on
Wasm sets a flag that callers check on the way out; it does not unwind, so statements
after it in the same body still run. Inside a `try_or` thunk that is an observably
different *result*, not just extra output — a buffer that reads `onetwo` on three
backends and `onetwothree` on the fourth. A gate with no place to say "these two
legitimately differ here" loses the first real divergence it finds, along with
everything else that test was checking. So a divergence is declared by a file next to
the case (`failure_caught.wasm.expected`) holding that backend's output **exactly**:
the known difference is pinned rather than tolerated, any other change is still a
failure, and the day that backend learns to unwind, the declaration breaks and says so.

**Two smaller things found on the way.** Passing a `test/parity/fail/` file as an
explicit argument ran it as an ordinary test and reported it as one the interpreter
could not run — arguments are partitioned by path now, the same way the defaults are.
And `__lang_str_concat("fail: ", msg)` in the C backend hung the program instead of
printing: this backend's strings carry a length header before byte 0, a raw C literal
has none, so the concat read whatever preceded the constant as its length. Same trap
that made `str_replace` return `""` in v0.1.233.

---

## v0.1.245 — 2026-08-14

_Ten builtins that existed only on the interpreter became ten definitions in the language.
Moving them exposed three bugs that had nothing to do with them, two of which were wrong
answers from builtins every test called correct._

```
  lib/prelude_stdlib.ml               sign incr decr square cube sum_range pow lcm divmod assert
  lib/eval.ml                         -105 lines: the ten builtins those replace
  lib/codegen_llvm.ml                 string globals minted once; int_of_str returns i64
  lib/codegen_c.ml                    gcd, random_int, file_size widened to long long
  test/parity/int_width.mere          new: every int builtin, with arguments above 2^31
  test/parity/show_json_same_program  new: show and to_json in one program
```

**The ten.** `sign` / `incr` / `decr` / `square` / `cube` / `sum_range` / `pow` / `lcm` /
`divmod` / `assert` were in the typer's environment and in `eval.ml` and nowhere else: they
type-checked on every backend and `mere -c` then emitted a reference to a name the C compiler
had never heard of. Defining them as Mere source in the prelude gives all five backends the
same one from one place, which is cheaper than five codegen cases and cannot drift between
them. `int_max` / `int_min` are deliberately not among them — they cannot be a portable
literal while int is 63-bit on interp and 64-bit elsewhere.

**"The same as the builtin" was wrong four times out of ten,** and only outside the range a
small test looks at. `sum_range` and `pow` recursed where the builtin was closed-form and
square-and-multiply, which is a stack overflow rather than a slow answer at a million terms.
`lcm` multiplied before dividing, which overflows for operands whose lcm fits but whose
product does not — on interp that made `lcm 3037000493 3037000493` answer `13`. And `divmod`
left its documented zero failure to `/`, which is not one thing across the backends: **bare
`x / 0` raises on the interpreter and returns 0 on C and LLVM**, so the failure would have
depended on which backend you built with. It has its own check now; the divergence in `/`
itself is still there and is not yet under any gate, because the parity harness compares
stdout and does not compare failures at all.

**The prelude definition shadows the builtin — measured, not assumed.** Making `eval.ml`'s
`sign` return 999 changed no answer, so the ten builtins were unreachable rather than
merely redundant, and 105 lines came out. The typer declarations stay: that is the set
`host_matrix.sh` generates its questions from, so deleting a declaration would have removed
the question rather than answered it.

**`@.s_true` was defined twice.** The first symptom of any of this was `to_json_composite`
failing to compile on LLVM with `redefinition of global '@.s_true'`. The show emitter and the
to_json emitter register their string constants in separate blocks, and they want some of the
same names — `s_true`, `s_false`, `s_lbracket`, `s_rbracket`. **Any program using both `show`
and `to_json` hit it**, which no test did until a prelude helper's error path called `show`
and gave every program a show emitter. Minting is idempotent by name now, and a second mint
with different content fails the compile instead of resolving last-wins.

**Then the value that found `lcm` found a real one: `gcd 3037000493 3037000493` was
`1257966803` on the C backend.** The generated runtime declared
`static int __lang_gcd(int, int)` while int is 64-bit there, so both arguments were truncated
to their low 32 bits. Nothing was missing and nothing failed to compile — the builtin was
recorded as present and correct on all four backends, because every probe of it had used a
one-digit literal. **The gap was in the values, not in the list of names.**

`test/parity/int_width.mere` is that gate, and it found the second one while being written
for the first: LLVM's `int_of_str` parsed with `strtoll` and truncated to `i32`, so
`int_of_str "3037000493"` was `-1257966803` and the largest int was `-1` — the return width
left behind when int widened to i64. `random_int` and `file_size` on C are the same shape and
are widened too, though neither is observable from a parity test (one is random, the other
needs a 2GB file). Sweeping both backends for the rest: every remaining narrow helper returns
a status code or a count bounded by a string's length.

**An intermediate has a width too.** With those fixed, one line still diverged:
`sum_range (0 - 3037000493) 0` has an answer both int widths hold and a naive Gauss
intermediate only the 64-bit one does. Halving inside the product — exactly one of the two
factors is even, since an odd count means the endpoints share parity — makes the function
portable over the whole range its result can hold.

---

## v0.1.244 — 2026-08-13

_The harness whose job is to ask which backend has which builtin was asking about a set
somebody remembered. Now it asks for the set too — and the answer is 144 builtins, not 50._

```
  bin/mere.ml             --dump-builtins: every name in the typer's environment, with its type
  scripts/host_matrix.sh  probes generated from those types; a new `nocompile` state
  docs/host-matrix.md     50 rows -> 144
```

**`mere --dump-builtins`.** One line per name in `Typer.initial_env`, `name<TAB>type`. The
compiler is the authority on its own environment, which is the same argument
`host_matrix.sh` already made for the *answers* — it just had not been applied to the
*questions*.

**Probes are synthesized from the type**: one literal per argument for `int`, `float`, `str`,
`bool` and `unit`, and a bare mention for a non-arrow. Anything needing a value a literal
cannot make — a `File`, a `Vec`, a `Channel` — falls back to a hand-written override, of which
there are 28. **70 of the 214 names are not synthesizable and are counted and named**, so the
part of the environment this harness cannot see is a number rather than a silence. A
synthesized probe that does not type-check is dropped and counted too.

**And a new state, `nocompile`.** `yes` used to mean "the backend emitted code", which is not
the same as working: `floor`, `ceil` and `round` emitted fine and the C compiler then failed
on an undeclared identifier. So for C the emitted source is now handed to a compiler, and the
row says `nocompile` when that rejects it. That state is exactly the blind spot those three
sat in for as long as they had been in the environment.

The matrix went from **50 builtins, 0 MISSING** to **144 builtins, 18 MISSING, 20 nocompile**.
The old number was not wrong — it was the answer to "is there a hole among the 50 somebody
listed", which reads like the answer to a different question.

Of the 20 `nocompile` rows, twelve are pure integer functions — `cube decr divmod incr
int_max int_min lcm pow sign square sum_range assert` — which want defining in the prelude as
Mere source, where all five backends get them at once. `exp` and `log` want libm cases beside
`sqrt`. Neither is done here: this change is about being able to see them.

Two rows that reported `error` were probe artifacts rather than defects — `map_new ()` alone
leaves its key and value types unresolved, and codegen correctly refuses. Both now have
overrides that pin the types, so the matrix reports 0 error.

---

## v0.1.243 — 2026-08-13

_A rasterizer, and the three math builtins it turned out no compiled backend had._

```
  contrib/raster/canvas.mere   premultiplied pixels, one blend, rects and clips
  contrib/raster/path.mere     antialiased polygon fill, curves, strokes
  lib/codegen_c.ml             floor / ceil / round
  lib/codegen_llvm.ml          floor / ceil / round
  lib/codegen_wasm.ml          the same three, refused loudly
```

**`contrib/raster`.** A pixel buffer, source-over compositing, and one antialiased
polygon fill that rectangles, glyph outlines, borders and strokes are all expressed in
terms of. Nothing here opens a window, and that is the point: turning a document into
pixels is checkable by comparing pixels, which needs no display.

**Premultiplied alpha**, so source-over is `src + dst*(255-sa)/255` on every channel with
no division by the result and no special case for a transparent destination. And `a*b/255`
is exact at both ends — the obvious `(t + t/255)/255` returns **256** for `255*255`, which
overflows the byte into the next channel of the packed colour. The first smoke test drew an
opaque black canvas instead of a white one, which is a good way for that to be found.

**Coverage is separate from alpha and multiplies it**, and the parity test asserts it:
coverage 128 with a solid colour and coverage 255 with a half-alpha colour must land on
the same pixel.

**Coverage, not sampling.** Each pixel row is cut into slices; per slice the edges are
intersected, the crossings sorted, and the spans added to a per-pixel accumulator
**exactly in x** — an edge at x = 3.25 puts 75% into pixel 3. Only y is quantized. Geometry
is float and coverage is integer, both measured rather than assumed: doubles print
identically across backends, and an integer accumulator cannot drift.

**And then: `floor`, `ceil` and `round` did not exist on any compiled backend.** Emission
*succeeded* and the C compiler then failed on an undeclared `mu_floor`, so nothing short of
a program that used them could notice — and nothing did, for as long as they had been in
`Typer.initial_env`. `sqrt`, `sin`, `cos` and `tan` were all handled; these three were
simply never added. Now on C and LLVM, verified identical to the interpreter including the
negative half-way cases (`round (-2.5)` is -3 on all three).

The Wasm backend **refuses all three, deliberately.** `f64.floor` and `f64.ceil` are
instructions and looked like a five-line addition — but putting the names in that backend's
eta-expansion list sent it into an infinite expansion, and a bare `floor` call never
finished emitting. `round` is worse than absent there: `f64.nearest` rounds half to even
where C and the interpreter round half away from zero, and doing it properly needs a scratch
`f64` local, which that backend declares per function. A backend that says "no" is one a
caller can work around; one that hangs, or that quietly rounds differently, is not.

**A survey, since one missing builtin implies others.** Fifteen names in
`Typer.initial_env` emit as undeclared identifiers on the C backend: `ceil cube decr exp
floor id incr int_max lcm log pow round sign square sum_range`. Three are fixed here. The
rest are recorded rather than fixed, because `scripts/host_matrix.sh` — the harness whose
entire job is to ask which backend has which builtin — has a **hand-written** case list and
covers none of them. Generating that list from the typer's environment is the actual fix and
is its own change.

`contrib/raster` runs on interp and C. The framebuffer is a `ByteBuf`, which the LLVM and
Wasm backends do not have, so they refuse at emit time and the harness records `UNSUP`
rather than a failure — C is what a native renderer targets and the interpreter is an
independent second implementation, so the gate still compares two.

---

## v0.1.242 — 2026-08-13

_A bug both hosts had, in a place the gate was only compile-checking. Backend parity could
not see it, because being wrong the same way twice looks like agreement._

```
  lib/codegen_c.ml     mem_get_u32be: long long, unsigned
  scripts/pg_env.js    getUint32, not getInt32
  lib/eval.ml          the byte arena, so the interpreter can run these programs
  scripts/ctest.sh     compare when both sides can run, compile-check when they cannot
```

**`mem_get_u32be` sign-extended.** It returned a C `int`, which widens into Mere's 64-bit int
with the sign — so `0xFF008080` came back as `-16777088`. Every opaque pixel has alpha `0xFF`,
so anything touching pixels hit it. It was also undefined behaviour rather than merely wrong:
`q[0] << 24` on an `int` promoted from `unsigned char` overflows a signed int once `q[0]`
reaches `0x80`. Now `long long`, computed unsigned.

**The JS host had the identical bug** — `getInt32` where `getUint32` was meant. Which is the
interesting part: **backend parity could not catch this, because both hosts were wrong the same
way.** That is the same shape as an exhaustive test file derived from the rules it tests, and it
is worth naming: agreement is only evidence when the things agreeing are independent.

**So what did find it?** A probe that opened a window, wrote a known pattern, blitted it and read
it back — when a pixel it wrote did not compare equal to the pixel it read. And what let it hide was `scripts/ctest.sh`: a program containing an
FFI declaration was compile-checked only, on the grounds that a bare extern has no linkable
symbol. True of an arbitrary name, false of the native FFI set — `mem_*`, `tcp_*`, `str_ptr`
and the rest get `static` definitions emitted, so those programs link and run. Their **answers
were never compared**.

The rule is now: **compare when both sides can run, compile-check when they cannot.** Requiring
the interpreter to run it too is what keeps this from firing on a program that would open a
socket — an extern the interpreter mocks is an extern somebody thought about.

**Which needed the interpreter to have the arena at all**, and now it does: the same bump
allocator over a fixed buffer, the same capacity, the same first offset, so the two agree on
arithmetic as well as on values. That also makes `contrib/db/pg.mere` runnable on the
interpreter, and it is a prerequisite for the raster work: a framebuffer is an arena.

`test/ctests/mem_arena_u32.mere` covers the round trip at `0x7FFFFFFF`, `0x80000000`,
`0xFF008080`, `0xFFFFFFFF` and the byte order, on both sides. Reverting the fix turns it red.

---

## v0.1.241 — 2026-08-13

_The one algorithm here with both kinds of gate pointed at it — which is what makes the
difference between them concrete rather than theoretical._

```
  contrib/unicode/normalize.mere    NFC and NFD
  contrib/unicode/nfc_table.mere    generated: ccc, decompositions, and the derived inverse
  scripts/gen_normalize_tables.sh   derives all three
  scripts/normalize_conformance.sh  20,034 UCD cases x 6 assertions
  scripts/unicode_parity.sh         + 8,755 inputs vs node's String.prototype.normalize
```

**`Normalize.nfc` and `Normalize.nfd`.** `é` can be one code point or two, and the two
spellings are the same text. Anything that compares text — an origin check, a cache key, a
search — has to pick one, and a renderer that draws both spellings differently is drawing the
same text two ways.

Three things carry the weight and only the first is obvious. **Canonical ordering** sorts each
run of combining marks by class, *stably*, because marks of equal class must keep the order
they were typed in. **A decomposition is not automatically a composition** — four kinds of
mapping are excluded from the inverse, and the generator applies and **counts** all four
rather than assuming them: 1,035 singletons, 4 non-starter decompositions, 81 script-specific
exclusions, and 3,833 compatibility mappings that are not canonical at all. 2,081 canonical
mappings in, **961 primary composites** out. And **blocking**: a mark reaches the last starter
only if nothing between them blocks it, which is why `q` + dot-below + dot-above composes
nothing while `d` + dot-below + dot-above composes only the first.

Hangul is arithmetic rather than table lookup — 11,172 syllables that would otherwise be
entries. Canonical mappings are stored **pairwise** and applied recursively, because the
longest one in the UCD is two code points and a pre-expanded table would need variable-length
values to buy a recursion a few levels deep.

**Both gates, and the reason neither substitutes for the other.** The UCD's conformance file
is exhaustive in ways no independent implementation is sampled for — canonical-order
permutations, PRI #29's chained composites, the closure of every composite — but it is derived
from the same rules this code reads, so a shared misreading would agree with itself. node's
`normalize` is independent but not exhaustive. So: **20,034 cases × 6 assertions** against the
file, and **8,755 inputs against node**, the latter derived from the generated tables so a row
nobody thought to test still gets one.

Six assertions per conformance line rather than two, because `NFC(c1) == c2` alone would pass
an implementation that is wrong about already-normalized input — which is the common case in
real text.

Both green on the first run, which for once is worth saying: the previous slice's gate found
three defects, and the difference is that this algorithm's hard parts (ordering, blocking) were
measured against node before the gate existed rather than reasoned about.

**Also**: the claim in `contrib/unicode/README.md` that a layout engine wants East Asian Width
"for advance widths" was wrong and is corrected. A renderer with a font takes advances from the
font's metrics. EAW is for terminal-style layout and for a fallback when there are no metrics,
which moves it down the list rather than up it.

---

## v0.1.240 — 2026-08-13

_The first gate here that is not an independent implementation — and it caught three
defects a careful reading of the rules had not._

```
  contrib/unicode/linebreak.mere    UAX #14, forty-four rules in the standard's order
  contrib/unicode/lb_table.mere     generated: 2,175 ranges, four UCD properties
  scripts/gen_linebreak_table.sh    derives the table
  scripts/gen_linebreak_testdata.sh vendors the conformance suite
  scripts/linebreak_conformance.sh  19,338 cases, all agreeing
```

**`LineBreak.opportunities`** says where a line is *allowed* to end. Not where it should —
that is the layout engine's decision, made with widths — but where the text permits one.

Three things make UAX #14 long, and none of them are the rules themselves. **LB9 and LB10
are a preprocessing step**: a combining mark takes the class of the character before it, so
the unit the rules see is a base plus its trailing `CM`/`ZWJ` run, except after a hard break
or a space where LB10 makes the leftover an `AL`. **"even after spaces" appears in six
rules**, each needing the last non-space class as well as the immediately preceding one, all
six sitting before the rule that breaks after a space. And **some rules look further than one
character either way** — LB25 needs a number state and two of lookahead, five rules need what
came before the previous character, LB30a needs a count.

**Four UCD properties in the table**, because several rules are written in terms of things
other than `Line_Break`: LB15a/15b test `General_Category` Pi and Pf, LB19a and LB30 test
`East_Asian_Width`, LB30b tests an unassigned `Extended_Pictographic`. LB1's resolution
happens in the generator, which lets the rules read the way the standard writes them.

**The gate is a different kind, and the difference cuts both ways.** UAX #14 has no oracle in
node: `Intl.Segmenter` has no `line` granularity and `Intl.v8BreakIterator` is gone. So this
runs the Unicode Consortium's own conformance file instead — **weaker**, because it is derived
from the same rules the implementation reads and a shared misreading of the prose would agree
with itself; **stronger**, because it is exhaustive over the pair table, every class against
every class with and without an intervening combining mark and space, which no hand-written
corpus would reach. It is vendored under `test/data` so it runs offline and cannot drift from
the table's version.

**It earned its keep immediately.** Three defects survived a careful reading of the rules:

* positions were reported **per unit rather than per code point**, so every case containing a
  combining mark was one short — 48% passing, and the pattern was uniform enough to name the
  cause before reading a second failure;
* **LB8a was called unreachable in a comment, and is not.** A ZWJ at the start of text has
  nothing to fold into, so LB10 turns it into an `AL` — but LB8a comes *before* LB10, so
  `ZWJ ×` still applies. Then the fix needed a second correction: the flag means "this unit's
  **last** code point is a ZWJ", so folding a combining mark on top of one clears it. The
  suite distinguishes those two readings in 24 cases;
* **LB19a's last line tests the character before the quotation mark**, not the mark itself.
  Three cases, all of them CJK text with curly quotes.

None of those would have been found by a corpus somebody wrote by hand, which is the argument
for the exhaustive-but-not-independent gate rather than against it.

---

## v0.1.239 — 2026-08-13

_A grapheme cluster is what a reader calls a character, and it is what a renderer has to
advance by. Four of UAX #29's rules are not local, and those four are the whole difficulty._

```
  contrib/unicode/grapheme.mere   UAX #29 extended grapheme clusters
  contrib/unicode/gcb_table.mere  generated: 1,631 ranges, three UCD properties folded into one
  scripts/gen_unicode_tables.sh   derives the table from the UCD
  scripts/unicode_parity.sh       8,509 inputs against node's Intl.Segmenter
```

**`Grapheme.clusters`.** `á` is one cluster, `👩‍👩‍👦` is one, `🇯🇵` is one, `\r\n` is one. Code
points are not the unit and neither are bytes — cursor movement, selection and glyph advance
all break visibly when the wrong one is used.

Most of UAX #29 is local: read the class of the code points on either side of a position and
decide. **Four rules are not, and the walk carries exactly four pieces of state, one per
rule.** GB12/13 needs how many regional indicators precede rather than whether one does
(`🇯🇵` is one cluster, `🇯🇵🇯` is two). GB11 needs whether the ZWJ was itself preceded by
`ExtPict Extend*` — the ZWJ alone does not say. GB9c needs whether a Linker appeared between
two Consonants, which is why the InCB property is in the table at all. And GB9b is decided by
the **left** character, the only rule that looks that way. `breaks_between` is written in the
standard's own order so it can be checked against it line by line.

**Three UCD properties folded into one class per code point**, from three different files
because that is how the UCD is arranged — and the folding is only sound because of three
facts the generator **asserts** rather than trusts: every `Extended_Pictographic` code point
has `Grapheme_Cluster_Break=Other` (all 2,848), `InCB=Consonant` is disjoint from the
non-Other breaks, and `InCB=Linker`/`Extend` live inside `Extend` or `ZWJ`.

**The table shape carried over unchanged from the JIS slice**, which is the point of having
settled it: 1,631 ranges as a fixed-width hexadecimal literal, fourteen characters each, with
`Other` as the unstored default. A lookup is a binary search rather than an index this time,
and nothing else about the decision changed — including the reason for hex, which is still
that a `str` is `strlen`-based on the LLVM backend.

**The Unicode version is pinned to the oracle's, before being bitten rather than after.**
`Intl.Segmenter` follows whatever node's ICU implements; a table of a different vintage would
differ from it for reasons that are neither a bug nor interesting. Both the generator and the
harness assert `process.versions.unicode`, so a node upgrade fails with one line instead of a
page of diffs. That is the node 22/24 lesson from `url_parity` applied in advance.

**The oracle here is worth more than the others in this repository.** It is not a second
reading of a specification this code also reads — it is ICU, which is what browsers ship.
8,509 inputs, none hand-picked: every ordered pair from 22 class representatives, every triple
from 8, every quadruple from 7 (which is what reaches `ExtPict Extend ZWJ ExtPict`), runs of
1..8 regional indicators and 1..5 of each repeating shape, and **both ends of every one of the
1,631 ranges in the generated table** — so a shifted range shows up as a segmentation
difference rather than waiting for a character nobody tested. All agreeing.

The corpus is generated once and written to a file both sides read, because writing the same
list of code points twice in two languages is how the two lists come to disagree.

---

## v0.1.238 — 2026-08-13

_The first table in this project too large to write as code — so it is generated, and the
question of what a 35KB literal does to five backends is answered by measuring it._

```
  scripts/gen_jis_index.sh        derives both JIS indexes from the Standard's own files
  contrib/encoding/jis_index.mere generated: 2 x 8,836 slots as fixed-width hex
  contrib/encoding/jis.mere       Shift_JIS and EUC-JP
  scripts/encoding_parity.sh      + 196,608 sequences, compared a different way
```

**The table question, settled by measurement.** A 35,344-character string literal compiles
and runs **identically on interp, C, LLVM and Wasm**, and `mere -rv` emits a 37,633-byte
RV32I image from it — so the worry about what a large literal does to a backend's rodata is
answered rather than assumed. (RV32I verified at emit; running it needs an emulator that
lives elsewhere.) No startup expansion, no data file, no compression: a slot is four O(1)
`char_at` reads.

**The encoding of the table is decided by the LLVM backend's `str`, not by size.** Raw 16-bit
values would be half as long, and are unusable: a `str` there is `strlen`-based and a raw
table is full of 0x00 bytes (U+00A2 is `00 A2`). Fixed-width hexadecimal is NUL-free by
construction, and `0000` doubles as the hole sentinel because U+0000 is not a mapping either
table produces. Two open questions meeting in one design decision is worth writing down.

**`contrib/encoding/jis.mere`.** Shift_JIS and EUC-JP. Four details that are easy to get
plausibly wrong: Shift_JIS's lead offset is **two** numbers (0x81 below 0xA0, 0xC1 above,
because the single-byte katakana range sits in the middle of what would otherwise be one
contiguous lead range); there is a **private-use window past the end of the table** (pointers
8836..10715 are U+E000 onwards, the vendor extensions the encoding grew); an unmapped pair
**puts an ASCII trail byte back** (`82 40` is U+FFFD then `@`, the same rule as UTF-8's);
and EUC-JP has **two tables and a three-byte form**, a 0x8F lead selecting JIS X 0212 for the
pair that follows it.

**The tables are derived from the Standard, not from node — and that is a change of oracle
with a measured reason.** node's `shift_jis` is ICU's CP932. Its `index jis0208` is
**identical** to the Standard's in all 8,836 slots, but its `index jis0212` maps **21**
pointers the Standard does not (from pointer 7708, the small Roman numerals), it remaps three
single bytes in a cycle (0x1A→U+001C→U+007F→U+001A), it treats 0x80 as an error where the
Standard returns U+0080, and its error recovery consumes a malformed sequence whole instead
of putting an ASCII trail back. A browser implements the Standard, and accepting 21 code
points the Standard does not is the same failure mode `contrib/url` guards against — agreeing
with an implementation instead of a specification, in the permissive direction.

So the generator reads the Standard's published index files and **pins each file's
`Identifier:` hash**, which is the oracle-version lesson applied to a data file that states
its own version.

**The gate keeps node, and asserts something exact rather than something weaker.** Strict
equality would be asserting ICU. Instead: **the two implementations never disagree about
which character a byte sequence is** — 75,547 inputs that both call characters, all
agreeing — and every remaining difference must be either error handling (U+FFFD on at least
one side) or the named three-cycle. Anything else is a table or pointer bug and fails. The
sweep is exhaustive over all three two-byte spaces (196,608 more sequences, 268,032 in
total).

That framing was not chosen up front. The first run reported thousands of differences; each
class was then measured and named, and what fell out was that the disagreements are entirely
about error handling and never about identity. A gate that says that is more useful than one
that says "equal".

---

## v0.1.237 — 2026-08-13

_A decoder's interesting behaviour is all in its error cases, and the Encoding Standard
specifies how many U+FFFD a malformed sequence produces — which is not one per byte._

```
  contrib/encoding/decode.mere   UTF-8, windows-1252, and the label table
  scripts/encoding_parity.sh     71,424 sequences swept against node's TextDecoder
```

**`contrib/encoding/decode.mere`.** Bytes off a wire into a `str`. Decoding never fails —
every malformed sequence becomes U+FFFD — so `decode_utf8` returns a `str` rather than an
`?str`. The only thing that can fail is recognising a label, and `decode` returns `?str` for
a *different* reason: the label named a real encoding that is not implemented yet, so a
caller can tell "unknown encoding" from "known but unsupported" and say so instead of
guessing.

**Two facts here are counter-intuitive enough to be worth stating outright.**

`ascii` **means windows-1252**. So do `latin1`, `iso-8859-1`, `us-ascii` and
`ansi_x3.4-1968`. The Standard folds them into one encoding on purpose, because that is what
the deployed web already did — so a page that calls itself `ascii` and contains byte 0x80
has a euro sign in it, and an implementation that "helpfully" treats `ascii` as 7-bit
produces U+FFFD where every browser produces `€`.

And **the replacement count is specified**: `F1 80 80 41` is one U+FFFD then `A`, because
those three bytes were a valid *prefix* and are one error together, while `E0 80 80` is
three, because `E0` requires its first continuation in `A0..BF` — so `80` is not part of the
sequence at all, and each remaining byte is then reconsidered on its own and fails on its
own. Getting this wrong changes how many characters a page has, which changes every offset
after it, and is invisible on valid input.

That same bound mechanism does all the other rejecting with no separate checks afterwards:
`ED` requires `80..9F`, which is exactly what keeps the surrogates unrepresentable, and `F0`
requires `90..BF` while `F4` requires `80..8F`, bounding the range at both ends.

**The gate sweeps rather than samples**, because the error cases are invisible on valid
input: every single byte (256), **every two-byte sequence (65,536)**, every three-byte lead
× first continuation (4,096), every four-byte lead × first continuation (1,280), and every
byte through windows-1252 (256) — 71,424 comparisons against node's `TextDecoder`. The
two-byte sweep is exhaustive; the three- and four-byte sweeps are exhaustive in the
dimension that carries the logic, with the rest held valid. Neither side builds an input as
a string literal — both loop over the byte — so there is no escaping layer to get wrong.
Labels are checked rather than derived (40 of them, including three that must *not*
resolve), and that gap is printed as a SKIP: the harness cannot discover a label nobody
listed.

**A new, measured consequence of the LLVM backend's `str`.** A decoded 0x00 is U+0000, and
because that backend's `str` is `strlen`-based, `str_of_codepoint 0` yields the **empty**
string — the character does not truncate the text, it **vanishes**, and every offset after it
shifts by one. `41 00 42` decodes to length 3 on interp, C and Wasm, and to length 2 on
LLVM. Silent loss is worse than truncation for anything that then indexes the result, so
this is documented as 0x01..0xFF-safe there for now, and `test/parity/encoding_decode.mere`
omits 0x00 with the reason written at the top rather than asserting the bug.

**Shift_JIS and EUC-JP resolve as labels but have no decoder yet.** They need the JIS X 0208
index — 6,879 code points — which is the first table in this project too large to write as
code, and that question deserves settling once rather than per encoding. `meta charset`
sniffing is likewise absent on purpose: it is a scan for tags and belongs with an HTML
tokenizer, and doing it in two places is how the two come to disagree.

---

## v0.1.236 — 2026-08-13

_An IPv6 address has many spellings and exactly one canonical form, so the serialiser is as
much of the answer as the parser._

```
  contrib/url/ipv6.mere    eight 16-bit pieces, in and back out
  scripts/url_parity.sh    + 53 IPv6 literals
```

**`contrib/url/ipv6.mere`.** `[0:0:0:0:0:0:0:1]` and `[::1]` are the same host, and until
now the host field carried whichever one was typed — a comparison on the text would have
called them different origins. Both now parse to the same eight pieces and serialise to
`[::1]`.

The serialiser's rules are narrow enough to get plausibly wrong while still looking right on
`[::1]`, which is what the corpus is weighted towards: the **longest** run of zero pieces is
compressed, ties go to the **first** run (`[1:0:0:1:0:0:1:1]` is `[1::1:0:0:1:1]`), and a
run of exactly **one** zero is left alone (`[1:0:2:3:4:5:6:7]` keeps it). `::` may stand for
a single piece on the way in — `[1:2:3:4:5:6:7::]` is `1:2:3:4:5:6:7:0`, which then
serialises without any `::` at all.

A trailing dotted quad occupies the last two pieces and is **strict** dotted decimal: four
parts, no leading zeros, no hex. That is deliberately *not* the multi-base parser a bare
host uses, so `[::0x7f.1]` and `[::01.2.3.4]` are not addresses while `http://0x7f.1` is
`127.0.0.1`. Two IPv4 parsers in one file looks like duplication and is not — they are
answering different questions, and the comment says so at both.

**Implementation note worth keeping.** The Standard's IPv6 parser is a pointer-walking state
machine over a mutable eight-slot array. This is the same algorithm expressed by splitting:
once on `::` (three parts means two of them, which is one too many), then each side on `:`,
with the zero fill computed from the two lengths. A trailing quad is folded into two hex
groups *before* the split, so nothing downstream has to know about dots — and anything else
containing one fails on its own, because `.` is not a hex digit. No mutation, and the
failure cases fall out rather than being enumerated.

---

## v0.1.235 — 2026-08-13

_Resolution against a base, hosts checked one byte at a time — and the first place the
oracle turned out to be wrong, which the harness now says out loud._

```
  contrib/url/host.mere    resolve; forbidden host code points; domains decoded
  contrib/url/percent.mere decode_strict
  scripts/url_parity.sh    + 272 resolve pairs, + 190 single-byte hosts, + DIVERGE
```

**`Url.resolve base input`.** What every link in a page needs: the reference wins wherever
it says anything and the base fills in the rest. A relative path replaces the base's last
segment and is then normalised, so `../d` against `/a/b/c` is `/a/d`; a reference that says
anything at all about the path drops the base's query, and one that says nothing keeps it.

The rule worth stating separately: **a reference carrying a special scheme that names the
base's own scheme is relative, not absolute.** `http:d` against `http://h/a/b/c` is
`http://h/a/b/d`; `https:d` against the same base is `https://d/`. Getting that backwards
turns a same-origin relative link into a request to a host the page named.

**Forbidden host code points, and domains are decoded.** A domain is percent-decoded before
anything else looks at it, so `%41` is `a` and `%2e` is a **label separator** —
`http://0x7f%2e1` is `127.0.0.1`. An allowlist that inspects the host before decoding sees
an opaque name where there is an address. A malformed escape means it is not a domain
(`http://a%b/` is not a URL, hence `Percent.decode_strict`), and the forbidden code points
are checked **after** decoding, so `http://a%2fb` has a `/` in its host and is rejected. An
opaque host is neither decoded nor folded, but the forbidden points still apply to it.

**Two new derived gates.** Resolution is checked as a **cross product** — 8 bases × 34
references = 272 pairs, each compared as `href` — because the interesting cases are
combinations, and picking pairs by hand is picking the ones already thought of. Hosts are
checked **one byte at a time**: `http://aXb/` and `foo://aXb/` for every X in 0x20..0x7E,
190 comparisons, with neither side building the string as a literal (both loop over the
byte, so there is no escaping layer to get wrong). That is the component where being too
permissive is worst, and it caught the missing forbidden-code-point check and the missing
domain decode together.

**And the oracle was wrong once.** The Standard's *no scheme state* admits a reference
against an opaque base only when the reference's **first** code point is `#`. node v24
accepts any reference that merely contains one — `new URL("?q#f", "mailto:x@y")` is
`mailto:x@y?q#f`, and `new URL("e?q2#f2", "mailto:x@y")` invents a path segment and gives
`mailto:x@y/e?q2#f2`. We follow the Standard, and the harness prints these as `DIVERGE`
lines with the count and both answers rather than dropping them from the corpus.

Overruling the oracle here and not elsewhere is a judgement, so the reasoning is recorded
next to it: the spec text is explicit (unlike the `^` in the path set, where the prose did
not name it and the implementation did), and the divergence is in the **permissive**
direction — accepting more than you should is the failure mode this gate exists to find. A
gate needs somewhere to say "the oracle is wrong here" or the first time it happens the
answer is to quietly delete the test.

---

## v0.1.234 — 2026-08-13

_The rest of the URL, and two places where the previous slice's simplifications
turned out to be wrong about where a delimiter stops mattering._

```
  contrib/url/path.mere    dot segments, query / fragment split, per-piece encoding
  contrib/url/host.mere    the authority rules corrected; href
  scripts/url_parity.sh    95 inputs vs node, nine fields each
```

**`contrib/url/path.mere`.** Splitting `rest` into path / query / fragment, resolving `.`
and `..`, and encoding each piece with its own set. The fragment starts at the **first**
`#` and the query at the first `?` before it; neither delimiter is special inside the
fragment, so `#a?b` is a fragment of `a?b`.

A dot segment is matched on the **whole** segment and includes its percent-encoded
spellings case-insensitively — `.`, `%2e`, `..`, `.%2e`, `%2e.`, `%2e%2e`. So `/a/%2E/b` is
`/a/b`, but `/a/..%2f` is left exactly as it is: `..%2f` is a segment that begins with two
dots, not a dot segment. And a **trailing** dot segment leaves an empty segment behind,
which is what keeps the trailing slash: `/a/b/..` is `/a/`, not `/a`.

The path is never decoded. `%41` stays `%41` and `%2f` stays `%2f` in whatever case it
arrived in — decoding an escaped slash into a separator is a path-traversal bug with a long
history.

An **opaque path** — no authority *and* no leading `/` — is not segmented and gets only the
`c0_control` set, which is why `mailto:a b` keeps its space. `foo:/a/../b` is `foo:/b`, but
`foo:a/../b` keeps its dots.

**Two things the previous slice had wrong, both found by widening the oracle corpus.**

* **A special scheme's authority needs no slashes, or any number of them.** `http:h`,
  `http:/h`, `http:\\h` and `http:///h` all have host `h`. The old code required `"//"` and
  rejected the rest, so it saw a relative reference where there was in fact a host — which
  is the shape of a real allowlist bypass. A backslash also *ends* an authority:
  `http://u\p@h/` has host `u`, because the `\` comes before the `@` ever does.
* **Backslash folding belongs to the path, not the whole URL.** The old code folded `\` to
  `/` across everything after the scheme. `http://h/a\b?c\d#e\f` has path `/a/b` but query
  `c\d` and fragment `e\f`, both keeping the backslash and both leaving it unencoded.

**`href`, and three booleans.** `has_authority`, `has_query` and `has_fragment` are fields
rather than being folded into the strings, because presence and content are separate state:
`foo://` and `foo:` have the same empty host but only one has an authority, and
`http://h/?` has an empty query that still serialises its `?`. `href` is what needs them,
and round-tripping is the honest test of a parse — a dropped field or an invented delimiter
shows up there and nowhere else.

**The gate is now one section of nine fields over 95 inputs**
(`scheme|user|pass|host|port|path|search|hash|href`), up from five fields over 24. `search`
and `hash` are derived from the two bools to match node's shape, where the delimiter is
carried when the component is non-empty and dropped when it is present but empty.

`test/parity/url_host.mere` grew to match, and `examples/url_parse_demo.mere` prints every
field of a parse. Both hold all four backends to one output.

One find worth writing down for anyone else generating Mere source from a shell: a `{` in a
string literal opens interpolation, so a corpus entry like `mailto:a{b` has to be escaped
as `\{`. The compiler's error message says so exactly, which is the only reason this cost
one run instead of an afternoon.

---

## v0.1.233 — 2026-08-13

_Two gates, two classes of bug: the oracle found three places the parser was too
permissive, and the backend-parity test found that `str_replace` had never worked
when compiled to C._

```
  contrib/url/host.mere        scheme / userinfo / host / port, WHATWG
  scripts/url_parity.sh        + authority section, 24 inputs vs node, per field
  lib/codegen_c.ml             str_replace: allocate a str, not a raw buffer
  test/parity/string_ops.mere  str_replace across four backends, with lengths
```

**`contrib/url/host.mere`.** The scheme and authority half of a WHATWG URL: cleaning,
the scheme, userinfo / host / port, and `origin`. `rest` hands the path, query and
fragment over untouched for the next slice. It returns `?url_parts` rather than failing,
because rejecting input is half of what a URL parser does — and on the wasm backend
`fail` sets a flag and returns a sentinel instead of unwinding, so a caller sitting
between the failure and its `try_or` still runs. A rejection has to be a value.

Two behaviours in here are the kind that become security bugs when an implementation
guesses. A host that parses as a number is an **address**, in any base the Standard
allows: `http://0x7f.1` is `127.0.0.1`, and an allowlist that only understands dotted
decimal passes it through as a hostname and then resolves it to localhost. And a domain
is lowercased while an opaque host is not — case folding belongs to the special schemes,
not to hosts.

**The authority gate: 24 inputs against node, compared field by field.** One line per
input as `scheme|user|pass|host|port`, so a mismatch names the field rather than just
the URL. Inputs node rejects must come back `None` from us too, because a parser that
accepts *more* than the oracle is the failure mode that matters for anything that then
makes a request. It found three:

* `http://256.1.1.1` and `http://1.2.3.4.5` were accepted as hostnames. Conflating "the
  IPv4 parse failed" with "so it must be a domain" is exactly the hole above, from the
  other side. Fixed by asking first whether the host *ends in a number*: if it does the
  host is an address and a bad one is invalid, and if it does not IPv4 never applies.
* `http://a@b@h/` produced an unencoded username. The userinfo set includes `@`, so it
  would re-split differently on the way out. Now `Percent.encode Percent.userinfo`.

**`str_replace` was returning a buffer with no length header on the C backend.** A Mere
`str` in C carries its length in a `size_t` at `[-1]`, written by `__lang_str_alloc`.
`__lang_str_replace` allocated with the raw `__lang_region_alloc` instead, so
`__lang_str_size` of its result read whatever bytes happened to precede the buffer in the
region. Those bytes were zero often enough that **every replacement came back empty** —
which is how this surfaced: `Url.clean` removes tabs with `str_replace`, so on the C
backend it returned `""` and every valid URL was rejected, while node and the interpreter
agreed with each other the whole time. The cap is a worst case, so the header is also
corrected down to what was actually written. The empty-needle guard now tests the length
rather than `old[0]`, so a needle that *is* a NUL byte is replaceable like any other.

A sweep for the same shape found no other instance: `__lang_str_alloc` is the only other
function that region-allocates directly, which is its job.

`str_replace` had no cross-backend coverage at all — only an interpreter test — which is
why this survived. `test/parity/string_ops.mere` now exercises eleven cases (shorter,
longer, equal, absent, whole-string, empty subject, empty needle, overlapping, UTF-8,
grow-from-one, then-concatenated) and **prints the length of every result as well as the
text**. The length is the point: the text alone would not have caught a garbage header on
every input. Reverting the fix turns that test red.

---

## v0.1.232 — 2026-08-13

_A percent-encode set is a list of bytes somebody transcribed, so it was checked against
somebody else's implementation instead._

```
  contrib/url/percent.mere   7 sets, encode / decode
  scripts/url_parity.sh      derives each set from node's URL, byte by byte
```

**`contrib/url/percent.mere`.** The URL Standard has no single escaping rule; it has a
stack of percent-encode sets, and which one applies depends on the component being
written. Getting the component wrong is not cosmetic — a `#` left unencoded in a path ends
the path. So `encode` takes the set as a predicate on a byte and the named sets are
supersets of one another: `c0_control ⊂ fragment`, and
`c0_control ⊂ query ⊂ special_query`, and `query ⊂ path ⊂ userinfo ⊂ component`.

Encoding walks bytes, not codepoints, which is what the Standard says and is the reason a
`str` being a byte buffer is the right shape here. Decoding leaves a `%` that is not
followed by two hex digits exactly as it found it: refusing would make a literal percent
sign unrepresentable, and decoding it as zero would invent a NUL.

**`scripts/url_parity.sh` derives the sets rather than asserting them.** For each byte in
0x20..0x7E it puts that byte alone into a component of an http URL, reads node's
serialisation back, and records whether it came out as `%XX`. That is node's set for the
component; ours is diffed against it. A fixture file would only have covered the bytes
somebody thought to write down — and this found two wrong sets on the first run:
`fragment` was missing `` ` `` and `path` was missing `^`.

`^` in the path set is in there because the oracle encodes it, which is not the same thing
as the prose naming it. That is recorded at the definition, so the next person sees a
citation rather than a magic number.

Four bytes per component cannot be probed this way and the harness prints them as SKIP
rather than passing them silently: a byte that delimits the component under test ends it
instead of being escaped in it, a lone space is stripped by URL parsing before escaping
happens, `.` in a path is resolved away, and `\` is normalised to `/` for the special
schemes.

`test/parity/url_percent.mere` holds all four backends to the same output.
`scripts/url_parity.sh` skips when node is absent, like `qemu_virt.sh` does.

**`contrib/http/query.mere`'s `url_encode` / `url_decode` are deliberately untouched.**
They implement the query-string convention a server wants — an allowlist of `alnum -_.~` —
which is not any of the Standard's sets. Changing them would change every existing
caller's behaviour, so the two live side by side with the difference written down.

Not here yet: the parser itself, punycode, and `decode` into `bytes`. That last one is
blocked on the llvm `str` being `strlen`-based, so `Percent.decode "%00"` differs by
backend; until that changes, callers that can receive `%00` should treat this as ASCII-safe.

---

## v0.1.231 — 2026-08-13

_The codepoint pair, written in the prelude rather than five times._

```
  str_of_codepoint : int -> str      codepoint_of : str -> int
  codepoint_at     : str -> int -> int
```

**Q-014's last deferred piece.** The Unicode question was settled in v0.1.38/45 — a `str`
is a UTF-8 byte buffer, with a codepoint view composed above it — and one sliver was left
open on purpose: the integer form of a codepoint, to be added "when an external program
asks for it." Percent-encoding and punycode ask for it.

It went in as **prelude source, not builtins**. The first attempt added them to the typer,
the interpreter and the C backend, and stalled at the point of hand-writing the decoder
in LLVM IR and WAT — at which point it was obvious the whole thing composes out of `chr`,
`ord` and `char_at`, which every backend already has. The codepoint layer has been
prelude-composed since v0.1.38 for the same reason. Six declarations, no codegen touched,
and all four backends agree because there is only one definition.

`chr` and `ord` stay byte-shaped: the redis, pg and http drivers build 0..255 bytes with
them. And the divergence `chr` carries — out-of-range raises on the interpreter and masks
on wasm and llvm — is not repeated: the new pair fails on all four. A scalar value is
0..0x10FFFF less the surrogates, and **overlong encodings are refused**, because two
spellings of one character is how a filter gets walked past.

`test/parity/codepoint_pair.mere` round-trips both sides of every length boundary
(127/128, 2047/2048, 65535/65536, 1114111) and refuses ten ill-formed inputs: negative,
above max, both surrogate ends, empty, two codepoints, truncated, `C0 80`, a bare
continuation byte, and a lead byte with nothing after it.

**Getting that file green on four backends turned up three older holes**, none of them
this change's:

- **The llvm `str` is not byte-safe.** The v0.1.129 work reached C and wasm; llvm still
  implements `str_len` as `call @strlen` and has no `__lang_str_size` anywhere, so a `str`
  holding a NUL cannot exist there. `str_len (chr 0)` is 1 on interp, C and wasm, and 0 on
  llvm, whose `chr` returns a raw pointer into a 256-entry table. U+0000 is left out of
  the parity file for this reason and checked in the unit tests instead.
- **`fail` does not unwind on wasm.** It sets a global and returns a sentinel, so whatever
  sits between the `fail` and the `try_or` still runs. `1 + (fail "b")` survives, because
  an integer tolerates the sentinel; `str_len (fail "b")` traps the module and the program
  dies without even the `try_or` default. Which failure you get depends on what the
  consumer does with the value.
- **`print` stops at an interior NUL.** `str_len` says 2 and `print` emits one character,
  on the same value. `print_bytes` (v0.1.219) is the byte-safe writer, but `print` is
  silently lossy rather than either correct or refusing.

Also: `codepoint_at` is `let rec` for a reason that has nothing to do with recursion. The
decl loop is duplicated in test helpers that bind `Top_let_rec` and `Top_let` separately,
so a plain `let` here reaching back to `let rec utf8_at` is unbound in those copies. Same
duplication that made the quadratic-inference fix land in six places.

---

## v0.1.230 — 2026-08-13

_A loop was a function calling itself, and whether it survived was up to clang._

```
  while, 200 000 iterations        before        after
    clang -O0                      SIGSEGV       ok      (10 000 000 ok)
    clang -O1 and up               ok            ok
```

**`while` never reached a backend as a loop.** The parser desugars `while cond do body`
into a tail-recursive `let rec`, so by the time codegen sees it there is nothing left
that says "iteration" — the C backend emitted a self-recursive function and left the
tail call to the optimizer. That made the iteration bound a property of the build:
`-O0` died with no output at somewhere between 100 000 and 200 000, `-O1` did not.

The build that dies is the one `scripts/debug_info.sh` prescribes: `clang -g -w -O0`.
So the debugger work of v0.1.212-215 — a compiled program you can step through against
its Mere source — and a program with a loop in it were mutually exclusive, and nothing
said so. A 100 KB input walked one byte at a time is 100 000 iterations.

`for i in a..b do body` was worse, not better: `range` materialises the whole range as a
list and `list_iter` then recurses down it. There was no safe way to iterate.

**A self tail call now lowers to a goto.** Tail position is tracked the way
`codegen_wasm` already tracked it — taken on entry to `emit_expr`, handed on only by the
cases where a subexpression really is in tail position (`Annot`, both arms of `If`, the
body of `Let` in each of its four pattern forms, the body of `Let_rec`, and match arms;
deliberately not `Region_block` or `With`, which have reclamation left to do after the
value). The call becomes argument temporaries, assignments to the parameters, and a jump:

```c
int f(vec* i, long long n, int u) {
  int __mere_ret;
  __mere_tail: ;
  return (cond ? ({ __auto_type __mt0 = i; ...; i = __mt0; ...;
                    goto __mere_tail; __mere_ret; })
                : 0);
}
```

`__mere_ret` is never evaluated; it is there to give the statement expression the
function's return type, which is what lets a `goto` sit in expression position at all —
the C backend is expression-oriented and cannot restructure a body into a statement
loop. Verified by hand first, with a struct return, before any of this was written.

**Two things the parity suite caught, both of which had built and linked cleanly.**

`schema_reflect` printed nothing. Rewriting `If` to name its operands had reversed the
order they were emitted in: OCaml evaluates the right argument of `^` first, so the
original chain emitted else, then, cond — and `emit_expr` interns strings and numbers
closures as it goes, so the order is part of the output. Restored, with a comment, since
nothing in the expression makes it look load-bearing.

Then it looped forever. `*(&p)` rather than `p` is why the assignments go through
aliases taken at function entry: `Json.parse_object` binds `let j = skip_ws s j` five
times, so by the tail call the name `j` is a local shadowing the parameter. Assigning by
name wrote the shadow and jumped with the parameter unchanged. The address is taken
before the body runs, so it names the parameter however the body rebinds that name.

Neither showed up in `dune runtest` or `ctest.sh` — the first needs a program whose
output depends on interning order, the second a function that shadows its own parameter
and tail-calls itself. `MERE_NO_TAIL_LOOP=1` disables the rewrite, which is what made
"is it this change?" a one-variable question; `MERE_TAIL_ONLY=<substring>` narrows it
to matching callees.

The prologue is only emitted for functions that actually produced a jump, so a function
with no self tail call is emitted exactly as before. That is per function, not per
program: the prelude has tail-recursive functions of its own, so **all 84 parity programs
contain a rewritten function**, which is what makes 85/0 there worth something rather
than an accident of coverage. `examples/bst.mere` has one of its own (`lookup`), and its
output is byte-identical before and after, at `-O0` and `-O2`, and against the
interpreter.

`__attribute__((noinline))` on the `show_*` helpers has a comment from v0.1.31 saying it
exists because an inlined helper's escaped local defeated clang's sibling-call
optimisation and deep loops overflowed. That was this bug, seen once from the other end
and worked around locally.

**The LLVM backend has the same defect** — `-O0` dies at 10 000 000, and the emitted IR
carries no `tail` marker anywhere. The fix there is `musttail`, which LLVM honours
regardless of optimisation level, but it requires the call to be immediately followed by
the `ret` of its result, and this backend has no tail-position notion and returns from
many places. Measured and left open rather than guessed at.

**`show` on a float gave four different answers.** The interpreter formatted it, C
printed `<unsupported>`, LLVM printed `()` — a number rendered as unit — and Wasm
printed `<?show_float?>`. Each backend's `show` generator simply had no float case and
fell through to a different placeholder. `parity.sh` never caught it because no program
in the suite showed a float; the probe that found it could not print the time it had
just measured. The formatter was already there and already shared, so this only wires it
up in the three generators. All four now agree, including `0.1 + 0.2` at 17 digits and
the trailing `.0` on whole values.

---

## v0.1.229 — 2026-08-13

_Formatting a long function was quadratic in two places, neither of them arithmetic._

```
              16 000 nested lets      22 810-line file
  fmt          1.30s  ->  0.05s        1.23s  ->  0.67s
```

**A run of `let ... in` is now written out as a run.** The formatter recursed into the
body and concatenated what came back, so every level copied the whole remainder of the
function into a new string. All 87 profile samples were inside `Stdlib.(^)`. Each
binding in a run sits at the same indent as the one before it, which is what makes the
run flattenable at all.

**`rename_free_vars` carried its shadow set as a list**, extended with `@`. That copies
the whole list at every binding, and each `Var` scanned it linearly — so a pass whose
entire job is renaming names cost O(depth²). It is a set now, which shares structure.
This one is not the formatter's: `mere -t` on the same input went 2.60s to 1.34s,
because every path that parses pays for it.

The formatter's output is unchanged: 193 files — every example, every `contrib` source,
every parity program, and a 22 810-line one — format byte-identically before and after.
That is the only acceptable evidence for a change to a formatter.

**What is left, measured rather than assumed**: `mere -t` on that 16 000-deep chain is
still quadratic (0.10 / 0.36 / 1.34 at 4k / 8k / 16k), because the type environment is
an association list and looking up a variable bound at the top of a function walks
every binding since. The deepest run of consecutive `let`s in this repository's own
sources is **281**, and those files type-check in 0.02s. So it is real, it is not
biting, and rewriting the environment on the strength of a synthetic chain is the kind
of thing Q-023 exists to say no to. Recorded as Q-026.

## v0.1.228 — 2026-08-13

_The support matrix is asked for rather than remembered, and it found three holes._

There have been three hand-written versions of "which backend has which host
builtin": a table in the design notes, and a list in each of `codegen_llvm.ml` and
`codegen_wasm.ml` naming the builtins with no lowering. All three had gone stale in
the same direction — `print_int` gained real lowerings in v0.1.190 and
`file_pwrite_bytes` in v0.1.222, and both were still listed as missing, in code that
is inert rather than wrong. A table nobody can trust is worse than no table.

`scripts/host_matrix.sh` produces one instead: fifty one-line programs, each using a
host builtin, emitted for each backend, and the outcome recorded as `yes`, `refused`
(the backend says so itself), `MISSING` (`unbound variable` — the compiler blaming
the user for a backend hole), or `error`. The result is `docs/host-matrix.md`, checked
in and diffed on every run.

The first run found three `MISSING`, all of them the failure this project's
loud-failure rule exists to prevent:

- **`read_bytes` and `write_bytes` on LLVM and Wasm.** They arrived with the `bytes`
  type in v0.1.216, *after* the per-backend lists were written, and fell straight
  through to `unbound variable`. The hole those lists exist to close, reopened by a
  later feature — which is exactly what a generated matrix is for.
- **`par_map` on Wasm**, which said `unbound variable: __pm_f1`: a name the user never
  wrote, about a function they do not know exists. `par_map` is desugared at parse
  time into spawn + channel + list_map, and Wasm cannot resolve the captured function
  from inside the nesting that produces. The limitation stands; it now names `par_map`.

The matrix is now 50 builtins, **0 MISSING**.

What it cannot see is a builtin that compiles and then does nothing — `tcp_set_timeout`
on Wasm in v0.1.227 returned success and hung. Only running a program catches that,
which is `scripts/parity.sh` and `scripts/socket_parity.sh`. The two kinds of check
answer different questions and neither replaces the other.

## v0.1.227 — 2026-08-13

_A capability that quietly did nothing now refuses._

`tcp_set_timeout` had a Wasm helper that ignored both arguments and returned `0` —
the same value the C version returns on success. So a program set a deadline, was
told it had one, and blocked forever on the next read. Measured at ten minutes
before it was killed.

That is worse than not having the capability at all: a missing feature is a compile
error, a silent no-op is a hang. It is refused at the call site now, with the reason,
until WASI's poll is wired up. A socket program that never sets a deadline is
unaffected.

**`scripts/socket_parity.sh`** is what found it, and is why this was possible to find
at all. `parity.sh` runs eighty-odd programs across four backends and **none of them
opens a socket**, because a socket program needs two endpoints and a host willing to
grant a network. So the whole socket family — `tcp_listen` through `tcp_close`, all of
it implemented against p2 `wasi:sockets` — had never been run. It works: the same
round trip prints the same four lines natively and under `wasmtime -S
inherit-network=y`.

Two things stay unequal and are recorded rather than fixed:

- **A failed read is `0` on Wasm**, the same value C uses for a clean end of stream.
  Distinguishing them means decoding WASI's `stream-error` variant instead of its
  is-error bit. The check above deliberately does not assert on it.
- **`sleep_ms` is interp + C only**, which is why the parity program contains no
  clock at all.

The general shape is the one the host-builtin registry work named: a capability with a per-backend
implementation and no single place that says which backends really have it. This is
the second silent gap found by running one, after `print_int` in v0.1.190.

## v0.1.226 — 2026-08-13

_A failed read says which failure it was._

```
> 0   bytes read
  0   the peer closed cleanly — end of stream, not an error
 -1   nothing arrived before the deadline
 -2   the connection is gone
 -3   anything else
```

`tcp_read` returned read(2)'s `-1` for everything. With `SO_RCVTIMEO` set that covers
two opposite events: the deadline passed with nothing arriving, and the connection
broke. One means wait again, the other means reconnect. The mraft dogfood told them
apart by timing the call and asking whether it had failed slowly enough to have been a
timeout — inferring a cause from a duration, and recorded as that repository's P4.

The codes stay negative, so every existing `< 0` check is unaffected.

`scripts/tcp_read_codes.sh` **produces** all three rather than describing them: a
socket nobody writes to, a peer that closes cleanly, and a peer that aborts with data
still unread in its own receive queue — which is what makes `close()` send RST instead
of FIN, and the only reliable way to get `ECONNRESET` without `setsockopt(SO_LINGER)`.

Two things this turned up:

- **The socket externs were documented nowhere.** Same as the positioned-IO family in
  v0.1.222: real, on every network program, and absent from the stdlib reference.
  Both are now in it.
- **Wasm disagrees about `0`.** Its `tcp_read` goes through WASI `sock_sread` and
  returns `0` on error, where C returns `0` only at end of stream. So a program that
  treats `0` as "the peer closed" is wrong there. No parity test covers sockets, which
  is why nobody had noticed; recorded rather than fixed, because fixing it means
  mapping WASI's error set and there is no Wasm program that opens a socket yet.

This answers the concrete case. The general question mraft's P4 asks — how a
capability reports *why* it failed, rather than only that it did, across an FFI
boundary that is C-shaped — is not answered by a convention about negative integers,
and is still open.

## v0.1.225 — 2026-08-13

_The editor stopped accepting names that no longer exist._

Rename a constructor and keep using the old name:

```mere
type t = Gamma | Delta;
let x = Alpha in print "b"      // Alpha was renamed away
```

The compiler says `unknown constructor: Alpha`. The language server said nothing —
clean file, no diagnostic, until the build failed. Three versions of one document,
driven through `mere lsp`:

```
v1  type t = Alpha | Beta;               clean
v2  type t = Gamma | Delta; ... Alpha    clean          <- wrong
v3  type t = Gamma | Delta; ... Gamma    clean
```

The parser has had `reset_decl_state` since a `type` in one program could shadow one
in the next. The **typer's** registries — constructors, types, records, views, drop /
sync / local types, record aliases — were never cleared. A compiler process checks one
program, so nothing ever noticed; a language server checks one document per keystroke.
The same leak made a `view Pair` and a later `type Pair` collide, which is how this
was found: a test declaring a record hit "view Pair must be constructed inside a
region block".

Two changes, and the second is the one worth reading:

- `Typer.reset_type_registries ()` runs next to the parser's reset. It restores a
  snapshot rather than emptying the tables, because the built-in capability records
  (`Logger`, `Metrics`) are registered at module load and a plain reset deletes them
  permanently. The snapshot is taken on the first call — which comes before any
  program's declarations are processed — so it does not depend on where in the file it
  is written.
- **What types exist is now established by `parse_program`**, not only by whichever
  later walk happens to visit the declarations. `Typer.infer` on a desugared program
  never registered anything, so a caller that skipped `process_decls` type-checked
  against whatever the *previous* program in this process had declared. Dozens of
  tests did exactly that and passed, because nothing was ever cleared: resetting
  without this made `Nil` unknown. Registering is idempotent, so the later walks are
  unaffected.

That second point is the real defect. The first is what exposed it.

## v0.1.224 — 2026-08-13

_A name bound by a constructor pattern can cross a thread boundary._

```mere
match ports with
| Cons (p, rest) -> let _ = spawn (fn () -> sender p out) in ...
```

That was refused with `cannot capture \`p\` of unknown type across a thread
boundary`, with `ports : int list` written down two lines above. The capture check's
pattern binder handled `P_var` and a tuple pattern over a tuple type, and bound
everything else — constructor patterns, record patterns — with an unknown type, which
makes those names unusable across `spawn`. The mraft dogfood hit it on every peer it
spawned a thread for, and the workaround (`let q = (p : int) in`, capture `q`) reads
like superstition because it is: an ascription that tells the program nothing it did
not already know.

The declared payload type is enough to do better, with no unification and nothing
this pass may mutate: the constructor registry knows the type parameters and the
payload type, and the scrutinee's own arguments say what to substitute for them.
Record patterns get the same treatment, field by field.

**The diagnosis in the dogfood's PAIN.md was wrong**, and worth recording as such. It
said the Send check ran before inference had propagated the annotation — a plausible
story about pass ordering, told without looking. The types were fully resolved; the
binder simply never looked at that shape of pattern. A payload whose type genuinely
is a variable is still refused, and now says so accurately (`of polymorphic type`
rather than `of unknown type`).

## v0.1.223 — 2026-08-12

_The reserved-name warning now looks at type names, which is where it was needed._

```
line 1, col 6: warning: type name `wait` collides with a C type, keyword or libc
symbol — this will be a compile error at codegen, from the C compiler rather than
from here.
```

A Mere `type` lowers to `typedef struct <name> <name>;`, which claims both C's tag
namespace and its ordinary one. `type wait = ...` therefore collides with
`union wait` in `<sys/wait.h>` **and** with the `wait()` declared beside it, and the
failure arrived from clang:

```
error: use of 'wait' with tag type that does not match previous declaration
```

The compiler has had a list of libc and C-keyword names since v0.1.55 and warns when
a top-level `let` collides with one. It never ran for `type` declarations. The mraft
dogfood named a type `wait` on its first day and got the collision from the C
compiler — the same "documented thing failing at the wrong layer" shape as the
`print_int` bug in v0.1.190.

The function list applies to type names unchanged (a typedef is an ordinary
identifier), plus a new list of the struct tags the emitted headers bring in:
`wait`, `tm`, `timeval`, `timespec`, `stat`, `dirent`, `sockaddr`, `addrinfo`,
`hostent`, `termios`, `winsize`, `sigaction`, `iovec`, `fd_set`, `div_t` and the
rest of that family.

Two things about the implementation are worth recording:

- **`Top_type` carries no position**, and adding one touches ten files. So the
  parser records `(name, loc)` for each type it declares — the same shape as the
  per-program tables it already keeps for constructors and records — and Pipeline
  reads that. A warning an editor cannot place is a warning nobody sees.
- The warning is raised on **both** paths: `process_decls`, which the compiler
  takes, and `infer_program`, which the editor takes. It went in on the first one
  only, and the test that checks it through `Pipeline.diagnostics` failed — which is
  exactly the test being worth writing.

Nothing in `examples/` or `contrib/` trips it.

## v0.1.222 — 2026-08-12

_A positioned write that takes the byte type the language grew afterwards._

```mere
let n = file_pwrite_bytes h off (bytes_of_str line)
```

`file_pwrite` was added for the mbtree dogfood in v0.1.115 and takes `Vec[int]`.
The `bytes` type arrived in v0.1.216 and got its I/O boundary in v0.1.219 — so the
language had a byte string, and the one API that writes at an offset could not take
it. The mraft dogfood's write-ahead log had to explode every record into a Vec with
**one boxed int per byte** before writing it.

`file_pwrite_bytes : File -> int -> bytes -> int` is the same operation over
`bytes`. Both remain: mbtree builds its pages as Vecs and has no reason to change.

All four backends, `test/parity/file_pwrite_bytes.mere`. Two of them cost almost
nothing:

- **Wasm**: the host import already took a bytes pointer — the Vec version converts
  first and then calls it. The new path is the same call with nothing in between.
- **LLVM**: one `fwrite` instead of a loop, since `bytes` is `{ i64 len, i8 data[] }`
  and `bytes_len` already loads from that layout.
- **C**: the runtime function had to be defined next to the bytes runtime rather
  than with the other `file_*` ones, because those are emitted before
  `struct mere_bytes` has a body — the same ordering the ByteBuf freeze hit in
  v0.1.218.

The LLVM path also registers the `Vec[int]` instance even though it uses no Vec: the
positioned-IO runtime is emitted as one block and `file_pread`'s body calls the Vec
accessors regardless. A program that only writes bytes carries a few unused
functions, which is cheaper than splitting the block into per-function flags.

## v0.1.221 — 2026-08-12

_A program's output no longer depends on whether someone redirected it._

`print` lowered to `puts`, and nothing in the runtime ever called `fflush`. C
line-buffers a terminal and fully buffers a pipe, so a program whose output was
redirected to a file printed nothing until it exited or accumulated 4KB.

Every dogfood until now was a batch program — it printed and exited, and exiting
flushed. The mraft dogfood is the first Mere program meant to be *watched while
running*, and it logged nothing at all: a server started with `> log 2>&1` looked
identical to one that had hung.

The C backend now emits `setvbuf(stdout, NULL, _IOLBF, 0)` in `main`; the LLVM
backend flushes after each `print` (`fflush(NULL)`, which needs no
platform-specific `stdout` global — glibc and macOS name it differently). Both
give piped output the same behaviour a terminal already had.

The LLVM change also removed a duplicate `declare i32 @fflush(ptr)`: the file
positioned-IO runtime had its own, and the second declaration is an error rather
than a redefinition LLVM tolerates. `scripts/parity.sh` caught it — `file_pio`
was the only program that emitted both.

## v0.1.220 — 2026-08-12

_Type inference was quadratic in the number of bindings. It is linear now._

```
                     inference (mere -t)      LSP, per keystroke
  4 000 bindings     0.16s  ->  0.02s          524ms  ->    32ms
  8 000 bindings     0.50s  ->  0.04s         1834ms  ->    65ms
 16 000 bindings     1.72s  ->  0.09s         7741ms  ->   135ms
 22 466 lines (real)                          5261ms  ->  1251ms
```

`generalize` decided which type variables to quantify by collecting the free
variables of **every scheme in the environment** and quantifying what was not
among them. That is the textbook definition, and it costs O(environment) per
binding — so checking N bindings cost O(N²).

Nobody noticed while the compiler only ran once per file. The LSP shipped in
v0.1.207 re-checks the whole document on every keystroke, which turned a cost
nobody paid into 5.3 seconds of latency per character on a 22k-line file. The
profile named one function.

The fix is levels (Rémy's ranks): each type variable records how many
generalizable bindings it was created inside, unification lowers that number
when a variable escapes into an outer type, and generalization quantifies
exactly the variables still deeper than the binding — no environment scan at
all. The `level` field on `Ast.tyvar` is the whole representational cost.

**The old definition is kept as an oracle.** `MERE_LEVEL_CHECK=1` computes both
answers at every generalization and reports any disagreement (add
`MERE_LEVEL_CHECK_TRACE=1` for a call stack). They agree on all 2421 tests and
on 390 further files — contrib, examples and the dogfood repositories. Since
the quantified set is the *only* thing this change can affect, that comparison
is the correctness argument, and the switch stays so the next change to the
level discipline is checked against the definition it replaced.

It found three real defects while being written, none of which any test caught:

- **`check_pattern` ran outside the binding's level**, so the fresh variables it
  makes for a tuple pattern's components dragged the value's variables out with
  them: `let (f, g) = (fn x -> x, fn x -> x + 1) in f` stopped being
  polymorphic. `pp_ty` prints `('a -> 'a)` either way, which is why the existing
  test passed.
- **`trait_elab` has its own copy of the declaration loop** and did not get the
  level discipline, which cost polymorphism for every binding in a program using
  traits.
- **The value restriction's monomorphic path** left variables looking local to
  the binding they had just escaped, so the next binding out would quantify
  them — the one direction of this change that would have been unsound.

The declaration loop now exists in six copies (three in `pipeline`, one in
`trait_elab`, two in the tests). Each had to be found and fixed by hand here.

## v0.1.219 — 2026-08-12

_`print_bytes` on Wasm, which makes it all four backends._

```
interp: 41004228290a
C:      41004228290a
LLVM:   41004228290a
Wasm:   41004228290a
```

Wasm was the one backend that had to refuse this, and the reason was the host
boundary rather than codegen: its printing goes through an `env.print_no_nl(ptr)`
import that reads a **NUL-terminated** string out of linear memory, which is
exactly what a byte sequence cannot be. So it needed a new import taking a
pointer *and a length* — `env.print_bytes(ptr, len)` — and the host side in
`scripts/run_wasm.js` to write that many bytes from memory.

**Gated on use**, like the imports around it: a program that does not call
`print_bytes` declares nothing new and runs on an older host unchanged. That
mattered here, since the playground ships prebuilt `.wasm` files.

_The test names both halves: the import must appear when the builtin is used, and
must not appear when it is not._

---

## v0.1.218 — 2026-08-12

_`ByteBuf[R]`: the mutable byte buffer that was missing._

_v0.1.216 gave `bytes` a way out of the program. What it still had no answer for
was building or editing one: `bytes` is immutable, `StrBuf` appends only and is
text, and `Vec[R, int]` does the job at **eight bytes per byte**. The thing that
asked for it was reconstructing a PNG scanline, which reads the row above it —
already reconstructed — and writes the row it is on. Random access both ways, and
bytes._

```
bytebuf_new  : int -> ByteBuf[R]                 n zeroed bytes
bytebuf_len  : ByteBuf[R] -> int
bytebuf_get  : ByteBuf[R] -> int -> int
bytebuf_set  : ByteBuf[R] -> int -> int -> unit
bytebuf_push : ByteBuf[R] -> int -> unit         appends, growing
bytes_of_bytebuf : ByteBuf[R] -> bytes           freeze a copy
bytebuf_of_bytes : bytes -> ByteBuf[R]
```

Region-bound like `StrBuf`, and for the same reason: the bytes live in a region and
the region is tracked by a pointer inside the struct rather than by the marker.
Freezing copies into the current region, so a `bytes` frozen inside
`region R { }` can be returned out of it — the mistake `strbuf_to_str` had to fix
once already.

**interp + C**, which is where byte I/O lives.

_Measured on the dogfood, decoding a 736×724 RGBA PNG: peak RSS **164MB → 117MB**,
with byte-identical output. The reconstructed image is 2.1MB of bytes, which was
17MB of `int`s._

_Adding the type re-found v0.1.217's P5 immediately, and twice — in both
directions. Once because `ByteBuf` was missing from the list of
region-parameterised constructors, so the marker erased to `int`. Then again with
the names the other way round, which produced the better fix: **a type whose C
representation does not depend on its region should not carry the region in its tag
at all.** `StrBuf` and `ByteBuf` both lower to one C type each, with the region
tracked by a pointer inside the struct, so `StrBuf___heap` was never carrying
information — only an opportunity to disagree. Both now tag as their bare name,
which removes the class rather than the instance, and gives `StrBuf` the fix for a
bug it had never happened to trip._

---

## v0.1.217 — 2026-08-12

_Two C-backend bugs the mpng dogfood found, both of which emitted C that a C
compiler rejects._

**A `let rec`'s names leaked into every later function.** The inner-fn lifting pass
keeps a set of names that are *not* captures — top-level names, builtins, externs,
and the siblings of a `let rec`. The sibling names were added to that set and never
removed, so a **later** top-level function whose parameter had the same name had it
taken for one of them: not recorded as a capture, and the lifted body then referred
to an identifier nothing declared.

The line that was supposed to put the set back read `let _ = known_before in`,
which does nothing. `known_before` was already being taken two lines above.

_What it took to see it: `png.mere` has an inner `let rec row`, `encode.mere` has a
parameter called `row`, and the second one lost it. Neither file alone reproduces,
which is why this survived — the failure needs two files and a name in common._

**An unresolved region marker tagged as `int`.** `ty_tag` erases a type variable
that survives to codegen (a dead result, an unconstrained value) to `int`, on the
reasoning that no operation ever inspects such a value. That is true of values and
false of a **region marker**: the marker sits in a type's first slot, the typedef
for the same type was emitted from a copy where it had resolved to `__heap`, and
the two spellings — `Vec_int_int` and `Vec___heap_int` — are a prototype for a type
that does not exist. An unresolved marker now tags as the default region.

_Both were found by compiling the program and running the result, which is what
`CC_CHECK=1` does in the dogfood and what `scripts/ctest.sh` does here. Neither is
visible on the interpreter; neither is visible from reading the emitted C without a
compiler. Both have twelve-line repros in the dogfood's PAIN.md, and regression
tests here that name the wrong spelling as well as the right one._

---

## v0.1.216 — 2026-08-12

_`bytes` gets its I/O boundary: `read_bytes`, `write_bytes`, `print_bytes`._

_The `bytes` type has existed for a while — `bytes_len` / `get` / `slice` /
`concat` / `of_hex` / `of_str` / `of_vec` and their inverses, across interp, C,
LLVM and Wasm. What it had no way to do was **leave the program**. Reading,
writing and printing a byte sequence all went through `str` or `Vec[int]`._

_Through `str` does not work, and the [mpng](https://github.com/284km/mpng)
dogfood found out the hard way:_

```mere
let _ = print_no_nl (chr 65);
let _ = print_no_nl (chr 0);
let _ = print_no_nl (chr 66);
```

_The interpreter writes `41 00 42`. Compiled with `-c`, the same program writes
`41 42` — a `str` is a NUL-terminated C string there, so `"\0"` and `""` are the
same value and nothing downstream can tell them apart. A PNG decoder writing a PPM
produced a file seven bytes short of correct, and only on some backends._

**The fix is not in printing.** A `bytes` carries its length in every backend
(`{ len; data[] }` in C and LLVM, an OCaml string in the interpreter), which is
what makes these three correct where `print_no_nl` cannot be:

| | |
|---|---|
| `read_bytes : str -> bytes` | interp + C |
| `write_bytes : str -> bytes -> unit` | interp + C |
| `print_bytes : bytes -> unit` | interp + C + LLVM |

_LLVM's writes through `write(1, …)` rather than `fwrite` to stdout: reaching
`stdout` from IR means naming a symbol that differs between platforms
(`__stdoutp`, `stdout`), and a file descriptor is the same everywhere — and
unbuffered, which is what the name promises._

_Wasm refuses `print_bytes` at compile time: its printing goes through a host
import that takes a NUL-terminated pointer, so this needs a host-side change
rather than a codegen one. Loud, not silent._

_The dogfood now reads and writes through `bytes` end to end, which is the check
that the design is the right one — 28 cases, on the interpreter and compiled,
producing identical files._

_Also noticed while testing, unrelated and unfixed: `exit 0` as a program's
trailing expression breaks the LLVM backend (`unsupported LLVM codegen type
element: 'a`, since `exit : int -> 'a`)._

---

## v0.1.215 — 2026-08-12

_`mere -ll -g`: the LLVM backend, too. Every backend can now be debugged as Mere._

```sh
mere -ll -g app.mere > app.ll && clang -g app.ll -o app
lldb app -o "b twice"
# Breakpoint 2: where = app`twice at app.mere:2:1
```

The same destination as the C backend's `#line` — a DWARF line table naming the
`.mere` — reached the most **directly** of the three, because LLVM IR carries
debug information itself. There is nobody to divide the work with: a
`DISubprogram` per function, a `DILocation`, and a `!dbg` on the instructions.

On *every* instruction, which is the constraint that shapes this. A function with
a subprogram whose calls have no location is something the verifier objects to, so
the location is attached in `emit_instr` — the one choke point every instruction
already goes through — rather than at chosen points. All of a function's
instructions share one location, the line its body began on, which is the same
granularity the C backend arrives at for an entirely different reason.

`Debug Info Version` in the module flags is not optional: without it the metadata
is stripped as being from an older LLVM and the debugger shows nothing, with no
error anywhere to explain why. It has a test of its own for that reason.

**`sh scripts/debug_info.sh`** compiles a program through both backends and asks
`lldb` where each function is, because a breakpoint resolving to `app.mere:8` is
evidence and emitted text looking right is not:

```
  ok    C    both resolves to app.mere:8
  ok    LLVM both resolves to app.mere:8
```

_That closes Q-021, and with it every backend: C `#line`, LLVM `!dbg`, Wasm a
source map, RV32I its own debug map — each reaching the same place by whatever
route its output allows. The interpreter needs none, being where the source
already is._

---

## v0.1.214 — 2026-08-12

_`mere -wg`, and a source map: the browser's debugger shows Mere source._

```sh
mere -w  app.mere > app.wat
mere -wg app.mere > app.map.txt
wat2wasm --enable-tail-call --debug-names app.wat -o app.wasm
node scripts/wasm_sourcemap.js app.wasm app.map.txt app.mere
```

Writes `app.wasm.map` and appends a `sourceMappingURL` custom section, which is
what Chrome and Firefox look for. The playground runs on this backend, so this is
the debugger a Mere program in a browser has been missing.

**The compiler cannot produce the map, and that is not a limitation but a fact
about the format.** A Wasm source map addresses *byte offsets in the assembled
binary*; this backend emits text for `wat2wasm` to assemble. So the work splits
the way the RV32I debug map splits: `mere -wg` says which function came from which
line, the binary says where each function ended up (its name section), and a
script joins them by name. Whoever knows the addresses is not whoever knows the
source.

**The check is the interesting part.** A source map is easy to produce and hard to
trust — the segments are VLQ deltas, so an error in one shifts every mapping after
it, and the result still looks like a source map. So `scripts/wasm_sourcemap.sh`
decodes the map back and compares it against `wasm-objdump`:

```
  ok    0x001550 is <both>, and the map says line 8
  ok    0x00155c is <thrice>, and the map says line 5
  ok    0x001564 is <twice>, and the map says line 2
```

_Prelude functions are absent from the table, by the rule v0.1.212 established: a
position that names a file did not come from the source being compiled. And the
binary still validates after the section is appended, which the check also
confirms — appending to a Wasm file is only harmless when it is done right._

---

## v0.1.213 — 2026-08-12

_Find references, and rename._

_The same question — where else is **this** binding — and the difficulty in both is
shadowing: two `x`es in one file may be two different things, and treating them as
one is a rename that breaks the program._

```mere
let x = 1;                        // renaming this one touches
let f = fn (n: int) ->
  let x = n + 1 in                // ... not this one, nor
  x + x;                          // ... these
let _ = print_int (f x + x);      // ... but these two
```

So the walk resolves **every occurrence to the binding it refers to**, and the
answer is the occurrences that resolved to the same one — the reverse of what
go-to-definition does, and the one shape `Query` was missing. Binder positions are
included, so the cursor may be on the definition rather than on a use.

**Rename refuses what the file does not own.** A prelude name or a builtin has its
definition somewhere the edit cannot reach, and renaming the uses while leaving
the definition is worse than refusing. The refusal is returned from
`prepareRename`, which is where an editor asks before offering a box to type in —
so it arrives as a message rather than as a broken file.

_That is the LSP's list done: diagnostics, hover, definition, completion, outline,
formatting, semantic tokens, references, rename. What is left is deliberate —
incremental sync (nothing to gain yet), and the twenty typer `raise` sites whose
worst case is one error per declaration rather than all of them._

---

## v0.1.212 — 2026-08-12

_`mere -c -g`: a debugger on the compiled program shows the Mere source._

```sh
mere -c -g app.mere > app.c && clang -g app.c -o app
lldb app -o "b mu_twice"
# Breakpoint 1: where = app`mu_twice + 8 at app.mere:2:40
```

_Verified with `lldb` and `dwarfdump`, not by reading the emitted text: the line
table names `app.mere`, and a breakpoint on a function resolves to the line it was
written on._

**This was reported as "not mechanical after all" in the notes for v0.1.202**, and
the reason given was that `codegen_c` is expression-oriented and does not know
which output line it is on, so `#line` — which applies to the *next* line —
cannot be placed. That turned out to be looking at the wrong thing. A function's
whole body is emitted as **one C line**, so a directive per function is not a
coarse approximation but the finest granularity the output has; put it inside the
braces and the body lands on exactly the line the programmer wrote. No
line-tracking writer, no second pass.

The other half of the problem is what to say about the code that has no Mere
source — the runtime, and the prelude. Each user function is followed by a
directive naming a file that does not exist (`<mere runtime>`), so a debugger
shows *no* source for those frames, which is the truth, rather than an arbitrary
line of the user's file.

**The rule for "is this the user's code" is one line**, and it is the one v0.1.210
made possible: *a position that names a file did not come from the source being
compiled.* Imports were already stamped; the prelude is now tokenised as
`<prelude>`, so neither can be claimed. An earlier attempt counted prelude
declarations instead and was wrong — `Trait_elab` reorders the list, so the
prelude's are not the first N by the time codegen sees them.

_Off by default: without `-g` the emitted C is byte-identical to what it always
was, which the suite checks. LLVM (`!dbg`) and Wasm (source maps) remain
unanswered; the RV32I backend has had its own since v0.1.200._

---

## v0.1.211 — 2026-08-12

_Formatting, an outline, and colour that is not guessing._

**`textDocument/formatting`** runs the function `mere fmt` runs. That is the whole
point of it living in `Pipeline` rather than in the CLI: format-on-save and the
command line cannot come to different conclusions about what formatted means. It
declines twice, deliberately — a file that does not parse is left alone, because
replacing a buffer with the best guess of a parser that failed is how somebody
loses work, and an already-formatted file produces no edit rather than an edit
that changes nothing. It also re-adds the trailing newline the CLI's
`print_endline` supplies, without which format-on-save would strip it from every
file, every time.

**`textDocument/documentSymbol`** lists the file's value declarations for the
outline, telling a function from a value by its type. `type` declarations are
absent and honestly so: `Top_type` carries a name and its variants and no
position, so it cannot be pointed at without guessing.

**`textDocument/semanticTokens/full`** is the compiler saying which names are
parameters, which are functions, which are constructors. Syntax highlighting is
normally regular expressions guessing at a language; this one does not have to
guess. The editor's grammar keeps what it is good at — keywords, strings,
numbers — and the distinction it *cannot* make, a parameter from a global, comes
from the tree.

_The encoding is five integers per token and every one is relative to the token
before it, which is compact and unforgiving: wrong deltas paint the file at an
offset. The test decodes the stream back into positions and names rather than
asserting on the numbers._

_The VS Code extension needed no change for any of this — it asks the server what
it can do during `initialize`, so three new capabilities simply started working.
That is the argument for keeping the two apart, arriving on schedule._

---

## v0.1.210 — 2026-08-12

_Positions know which file they came from, and the typer reports more than one
problem per declaration._

**A position carries its file.** `Loc.t` gained `file : string option`, and since
the lexer is the only thing in the compiler that builds a position, stamping the
tokens of an `import`ed file was a one-line change that everything downstream
inherits: an error raised deep in the typer, about a node that came from another
file, now knows which file it is about without anybody having threaded that
through. The CLI renders the snippet from that file; the language server publishes
against that file's URI. Before this, only *syntax* errors could say where they
came from — by the time the typer runs, imported declarations have been merged
into one program.

**The typer collects.** The two sites that account for nearly every real type
error — a mismatch in `unify`, and an unknown name — report and carry on instead
of raising, when a sink is installed. So one declaration can report four problems
rather than the first one.

What it carries on *with* is the interesting choice: a **fresh type variable**,
which unifies with anything, so it neither invents a second error nor silences a
real one further along. A distinguished error type would be the textbook answer
and would have to be taught to every match on `ty` in five backends. On a
mismatch the two types are left unlinked, since neither is more right than the
other and forcing one on the other is how one mistake becomes five.

The other twenty `raise` sites are unchanged: they end that declaration's check,
and v0.1.209's recovery picks up at the next one. The compiler's path is
untouched — no sink, same first-error-raises behaviour — and the sink is installed
under `Fun.protect`, because one left behind would make the compiler collect
errors instead of stopping. There is a cap of a hundred, because a pathological
file can produce errors without end once inference is allowed past them and
nobody is reading the hundred and first.

---

## v0.1.209 — 2026-08-12

_More than one type error at a time._

_A file with three broken functions reported one of them: fix, recheck, learn
about the next. The check now recovers at **declaration** boundaries — the same
boundary the parser recovers at — so it reports one error per broken declaration,
in the editor and in the terminal._

```
type error: expected `int`, got `str`
  --> app.mere:1:28
type error: expected `int`, got `str`
  --> app.mere:2:24

2 errors
```

**A declaration that failed still binds its names**, to a fresh type variable that
unifies with anything. Otherwise every later use of the name is a second error
about the same mistake and the real ones are buried — the test for that uses a
broken function twice and expects exactly one error.

**The compiler's path is unchanged.** Recovery is opt-in (`infer_program
?on_error`): without it the first error is raised exactly as before, because a
compiler that carries on past a type error has nothing useful to emit. One code
path, two behaviours, rather than a second implementation to keep in step.

_The typer still stops at the first problem **within** a declaration. Making that
collect means teaching every one of its 22 `raise` sites to produce a value and
carry on — a different and much larger change, and one that needs an error type
that unifies silently, or every recovery invents cascades of its own._

_One wrinkle worth recording: the pass over the desugared program re-visits every
declaration's body, so it re-raises the error the declaration loop already
reported. Diagnostics are de-duplicated, which is what makes that harmless — and
is the same fix the duplicated exhaustiveness warnings needed in v0.1.208._

---

## v0.1.208 — 2026-08-12

_Diagnostics become data: which file a position belongs to, and warnings too._

**A syntax error inside an `import` is reported against the file it is in.** Its
line numbers describe *that* file, so reporting it against the importing one was
underlining an innocent line. `Parse_error_in_file` carries the path from the
import that raised it, the CLI renders the snippet from that file, and the
language server publishes against that file's URI — remembering which other files
it has spoken about so it can clear them when the import is fixed. A diagnostic
stays on an editor's screen until the server says otherwise, and "never mind" is
exactly the message nobody thinks to send.

**Warnings are diagnostics now** (severity 2 in the protocol): a non-exhaustive
`match`, a top-level name that collides with a C keyword. They were printed to
stderr from inside the pipeline, which is fine for a terminal and useless to
anything else — an editor cannot underline a line written to a stream it is not
reading. The pipeline collects them; the CLI prints them, which is where the
decision about how a warning looks belongs.

Two things that fixing this exposed. The non-exhaustive-match warnings arrived
**twice**, because type inference visits a declaration's body once as a
declaration and again as part of the desugared program — de-duplicated now. And
the messages carried their own `line L, col C:` prefix, which read as
`warning: line 3, col 29: warning: …` once a caller with the position added its
own; the position is data and the text no longer repeats it.

_Still not carried: **type** errors from an imported file. By the time the typer
runs, the imported declarations have been merged into one program and nothing
records which file each came from._

---

## v0.1.207 — 2026-08-12

_Completion — the third of the three questions that are really one question._

_Fifth slice of the language-server arc, and the one that needed no new
machinery: `Query.scope_at` already knew what is visible at a position, so this is
that list, de-duplicated by name and dressed for the protocol._

Every name visible at the cursor, innermost first, one entry per name — an inner
binding shadows an outer one, and offering both would offer a name that cannot be
reached. Each carries its inferred type as the `detail` line and a kind, so an
editor draws a function icon for a function.

Two judgements about what *not* to offer: the prelude's internal helpers (the ones
it names with a leading underscore) are left out, and `_` is not a name anybody
wants back. Prelude names themselves are offered — `str_len` is exactly what you
want in the list — with `sortText` putting them after the file's own names.

_That completes hover / definition / completion. All three are `Query.node_at` and
`Query.scope_at` with a different answer attached, which is what moving the check
into the library bought: the editor's three questions turned out to be one
question the compiler could already answer._

---

## v0.1.206 — 2026-08-12

_Go to definition._

_Fourth slice of the language-server arc, and the first that needs **scope**: not
just what is under the cursor, but what is bound there and where each name came
from._

**Scope is recomputed, not indexed.** `Query.scope_at` walks down to the position
and collects the binders on the way. The walk descends one path rather than the
whole tree, it cannot go stale, and there is no invalidation to get wrong — the
same reason hover reads the typer's annotations instead of building a table beside
them.

A binder covers the parts of itself where it is really visible: a `let` binds its
body but not its own value expression, a `fn` binds its body, a `let rec` binds
both, a match arm's pattern binds that arm. Each of those is a test, because
getting one wrong is how a server sends you to the wrong `x`.

**Two answers it declines to give**, both because the honest answer is nothing:

- A **prelude name** (`print_int`) is genuinely in scope, but its position is a
  line in the prelude's own text — jumping there would send the editor to an
  arbitrary line of the user's file. Prelude bindings are therefore *marked*
  rather than dropped (completion will want them), which needed the pipeline to
  record how many declarations the prelude contributed.
- A **parameter** resolves to the `fn` that introduced it rather than to the
  parameter name, since `Fun` carries the name but not the name's own position.

---

## v0.1.205 — 2026-08-12

_Hover: the type inference gave whatever is under the cursor._

_Third slice of the language-server arc. Point at a name and the editor shows
`twice : (int -> int)`; point at a literal and it shows `int`._

**There is no second inference pass and no index.** The typer already writes the
type it found onto every node it visits (`e.ty <- Some t`), so the check that
produced the diagnostics leaves behind a tree that knows the answer. `Pipeline.check`
now hands that tree back instead of dropping it, and the server keeps it per open
document.

**What "the node at this position" means here**, since it is not obvious: a `Loc.t`
in this compiler is a line, a column and a **width** — the token a node was built
from, not a span over its subtree. So the node at a position is the *narrowest*
node whose own token contains the cursor. That is what makes hovering inside a call
answer about the piece under the cursor rather than about the whole application.
`Query.node_at` is that search, and `Ast.children` is the one generic child walk it
needed — written once, because every position question (this one, go-to-definition,
completion) needs it and three hand-written 26-case matches would drift apart.

**The last tree that type-checked is kept.** While a line is half typed the file
does not check, and an answer from a moment ago beats no answer at all — so hover
keeps working through an edit and catches up when the file is valid again. The test
for this edits a good file into a broken one and asserts the tree survived.

---

## v0.1.204 — 2026-08-12

_`mere lsp` — a language server. Diagnostics in the editor, from the check the
compiler runs._

_The second slice of the language-server arc (the first was recovering from
syntax errors, so there is more than one to show). What it does is diagnostics:
every syntax error in the buffer, republished on each keystroke, and the first
type error once the file parses. Hover and completion want a position resolved
against a typed tree, which is the next slice._

```sh
mere lsp        # LSP over stdin/stdout; see docs/lsp.md for editor setup
```

**The check is the compiler's check.** `infer_program` — parse, elaborate, type,
plus the borrow/move/Send analyses — moved out of the CLI into `Pipeline`, where
the server calls the same function the four backends start from. A language
server that agrees with the compiler on good days is worse than none: it teaches
you to distrust the underline. `Pipeline.diagnostics` is the one entry point that
answers "what is wrong with this text", as data rather than as an exception.

**Everything the server decides is a function.** `Lsp.handle : state -> message ->
state * message list * bool` — so the protocol is tested in the suite without a
socket, a subprocess or an editor, and the only untested part is three lines of IO
in `Lsp.serve`. `scripts/lsp_smoke.sh` covers the process end to end by piping a
canned editor session through the real wire format.

**Also new: `Json`** — a JSON value, parser and writer (~230 lines), because this
project has two dependencies and reading a protocol this small is not worth a
third. It decodes `\uXXXX` into UTF-8 including surrogate pairs, and prints
integers without a decimal point, since an editor reading `"line": 3.0` strictly
is entitled to object.

_Known gaps, all written down in `docs/lsp.md`: one type error at a time (the
typer still raises on the first), positions inside imported files are reported
against the importing file, and sync is full-text rather than incremental._

---

## v0.1.203 — 2026-08-12

_The parser no longer stops at the first syntax error._

_A file with three broken functions told you about one of them, three times in a
row: fix, recompile, learn about the next one. `mere <file>` now reports all of
them, in source order, with a count at the end._

```
parse error: expected literal, identifier, or '('
  --> app.mere:3:20
parse error: expected type
  --> app.mere:7:16
parse error: expected 'ident = expr' after 'with'
  --> app.mere:12:15

3 syntax errors
```

_This is the first slice of a language-server arc, and it is the one that pays off
on its own: an editor cannot underline three mistakes if the compiler only knows
about one, and neither can a person._

**How.** `Parser.parse_program_recover` parses, and on an error **deletes the
declaration that contains it** and parses the whole file again, collecting errors
until it succeeds (or hits 20). Re-parsing rather than resuming is deliberate: the
parser is functional over an immutable token list, so there is no cursor to reset
and no half-built state to unwind — deleting a span and starting over is exact, and
it needs no changes to the 130-odd places that raise. It costs one pass per error,
which for an editor re-parsing on every keystroke is not the expensive part.
`parse_program` itself is untouched, so nothing on the good path changed.

**Where a declaration ends** is the interesting part. `;` at bracket depth zero is
the language's real boundary — but a declaration with an unbalanced `(` never
returns to depth zero, so a depth-only rule deletes the rest of the file and hides
every later error, which is the exact failure being fixed. So a **declaration
keyword in column 1** is accepted as a boundary too: every top-level declaration in
this language's sources starts flush left (the formatter emits nothing else), so an
indented `let` is a local binding and one in column 1 is a new declaration. It is a
heuristic, and it is consulted only about where to resume after an error.

_Errors from an **imported** file are not recovered from — their positions belong to
another file's token list, so there is nothing in this one to delete. The first is
reported and the walk stops._

---

## v0.1.202 — 2026-08-12

_Two loose ends from the bare-metal work: diagnostics that report the line you
wrote, and the differential test the QEMU port was aiming at._

**The line you wrote.** The `-rv` path compiles a *concatenation* — a Mere-source
runtime prelude, then the user's file — so every position it produced was counted
from the top of that text, and a type error in a three-line file was reported at
"line 133", against a snippet from an unrelated line or none at all. The debug map
already subtracted the prelude; the diagnostics did not.

One function now answers "where is this really?" for both, so they cannot drift
apart. A position that lands *inside* the prelude is deliberately **not** remapped
into the user's file — there is no honest line there to point at — and is shown
against the prelude's own text under the name `<rv-prelude>`, which also makes a
prelude bug legible as one.

**Two independent machines, same bytes.** v0.1.201 booted a bare program and a
trap handler on QEMU's `virt` board. Two additions finish the thought:

- `examples/riscv_virt_sched.mere` — the **context switch** on virt. This is the
  case most worth an outsider's opinion: the trampoline saves 31 registers to a
  known place and the emulator restores them, so if the two agreed on a wrong
  order, order-dependent corruption would be invisible to every test we own. It
  also checks the rule that was hardest to arrive at (`gp` switches with the rest,
  because each task has a heap of its own) against a machine with no stake in it.
- `scripts/qemu_virt.sh` now takes `MEMU=<memu checkout>` and runs each image on
  **both** machines — QEMU and the Mere-written emulator — diffing the two. All
  three examples are byte-identical on both.

For that diff to mean anything the output has to be a function of the program
rather than of the clock, so the scheduler prints one letter per **switch** rather
than one per N iterations: virt gives each task 20ms of real time, our emulator
counts instructions, and both print `ABABABA`.

_The emulator side of this is in the memu project: `./rvrun 8 virt` places RAM at
2GB and moves the CLINT to virt's addresses. What had to change there was the
decode *order* — it asked "is this a device?" first, which is only right while the
devices are above RAM._

_Still not on virt: the shell (its input would have to be piped in to be diffable)
and the user-process pair (a second image needs `-device loader` rather than
`-kernel`)._

---

## v0.1.201 — 2026-08-11

_The backend's output boots on a machine nobody here wrote: QEMU's `virt` board._

_Every layer of the bare-metal work is self-written — the compiler, the fifth
backend, the kernel, and the RV32I emulator it runs on. So when something
misbehaves, "is the binary wrong or is the emulator wrong?" has no answer inside
the stack; agreeing with yourself is not evidence. QEMU is an independent
implementation of the same specification, which is what the Klaus and Blargg
suites are for the 6502 and Game Boy emulators in the sibling project._

```sh
mere -rv --bare --load-base 0x80000000 --ram 8 examples/riscv_virt_hello.mere > virt.bin
qemu-system-riscv32 -M virt -bios none -nographic -kernel virt.bin
```

_Two programs boot: `riscv_virt_hello.mere` (UART, a run-time-allocated string,
recursion, the CLINT read back) and `riscv_virt_timer.mere` (a registered Mere
closure servicing a real timer interrupt). `sh scripts/qemu_virt.sh` builds both,
runs them and diffs the output; it skips cleanly when QEMU is absent, so this is
an optional check rather than a dependency._

_What QEMU checks that our own emulator cannot: instruction encodings against a
decoder nobody here wrote, the layout `_start` builds at a load base above 2GB,
the 16550 protocol against a real device model, and — the one most worth an
outside opinion — the trap contract: `mtvec`, `mstatus.MIE`, `mie.MTIE`, the
CLINT's compare register, and the PC a handler returns for `mepc`._

_The **one** thing that had to change in codegen: the machine window's length is
now a `max` rather than a sum. It was `mmio_base + mmio_len`, which is right only
while the devices are above RAM — the arrangement the default base 0 forces. virt
inverts it: DRAM at `0x80000000` with every device beneath it, so a program handed
`[0, 0x10010000)` could not name its own RAM. The bounds checks were already
unsigned, so a length past 2GB is not a negative number to them._

_Also: the `-rv` family's flags (`--bare`, `--ram`, `--load-base`) are now parsed
in any order rather than matched as literal argument lists, which is why the
combination this needed — all three at once — did not exist before. That removes
eight arms whose only distinction was which combinations somebody had happened to
want._

_Not yet on virt: the scheduler, shell and user-process examples (they name our
CLINT addresses; the shell wants a receive side; a second image needs `-device
loader`), and running a virt image on our own emulator, which would make the same
bytes runnable on both. Both are address swaps rather than redesigns — see
`docs/bare-metal.md`._

---

## v0.1.200 — 2026-08-11

_`mere -rvg`: a debug map, so a program compiled to machine code can be debugged
at the source lines it was written as._

_Nothing in any backend emitted debug information — no DWARF, no source maps, no
line directives — so "which line is this?" was unanswerable everywhere. On the
RV32I backend that showed up as a working method: every hard bug in the bare-metal
arc was found by instrumenting the emulator **by hand**, a ring buffer of program
counters here, a store watchpoint on a save area there, a register dump at trap
entry. Ten instruments, written and thrown away, and once by patching codegen to
print two registers from inside `__oom`._

_The map is a text sidecar, because the binary has no header to hold anything —
this backend emits code and nothing else. One record per line, addresses
ascending:_

```
S <addr> <name>                                 every label
F <addr> <name> fsz= ra= fp= params= line=      a function and its frame
L <addr> <line> <col>                           the statement starting here
```

_Two properties it was worth designing for. It is emitted from **the same item
list the assembler consumes**, via a zero-width `Meta` item that the assembler and
the listing both ignore — so `-rv` and `-rvg` agree by construction, there is no
separate debug build, and the map describes the bytes that actually ran. And the
line numbers are the ones **the programmer wrote**: source positions arrive counted
from the top of the prelude-plus-source text the driver builds, and the map
subtracts the prelude, so an address whose line lands inside the prelude gets no
record — the honest answer for code nobody wrote. (That offset is the same one
that makes `-rv` diagnostics report line 133 for a three-line file; fixing the
diagnostics is a separate change.)_

_Frame layout is uniform on this backend, so `fsz` / `ra` / `fp` describe it
completely and a backtrace is two loads per frame with no guessing._

_The reader lives in the memu project as `riscv-dbg`: breakpoints on source lines,
a backtrace, and **reverse stepping** through an undo log — one fixed-size record
per instruction, so going back applies the inverse rather than replaying from a
snapshot. It is exact, and tested as such (N instructions forward and N back
restore every register and a checksum of the heap), and it crosses traps: `S`
walks out of an interrupt handler and onto the line the timer interrupted. Which
is the shape of the thing this arc kept needing and building by hand._

_Three tests on the map. `dune runtest` 2339/0, ctest 13/13._

---

## v0.1.199 — 2026-08-11

_Documentation for the bare-metal work, which existed only as twelve changelog
entries and seven example headers._

_The arc built a fifth backend, an operating system on it and a user process on
that, and none of it was discoverable: the README did not mention RV32I at all,
`codegen.md` documented three backends, and the nine new examples were missing
from the category index. Someone arriving at the repository could not find the
tower, let alone the rules for using it._

_[docs/bare-metal.md](bare-metal.md) is now the one place: flags, the memory map,
raw memory as a window capability and the three ways out that are closed, CSRs
and why they are deliberately **not** a capability, the trap trampoline and its two
non-obvious properties, tasks, and **when to switch `gp`** — the rule that took
the arc's hardest bug to find. It ends with what is deferred on purpose (the
fantasy console's ambient framebuffer, a QEMU boot for external verification,
nested traps, and the absence of an MMU) so the gaps are recorded rather than
implied._

_Also stated plainly there, because it would otherwise be easy to overclaim: what
isolates the user process is **the type system, not the hardware**. Everything
runs in machine mode; the process is contained because without `--bare` it cannot
obtain a `Raw` at all, not because an MMU would stop it._

_The examples index gains a section in the same shape as the browser apps —
each example beside the thing it forced — and a broken link found on the way
(`contrib/json/writer.mere`, merged into `json.mere` in 31b4c45) is fixed where
this file referenced it._

---

## v0.1.198 — 2026-08-11

_The allocating-handler corruption, solved. The mechanism was none of the three
suspects — it was `region`, and the "fixed" shell had been quietly broken all
along._

_The tell was in the emulator's register log: task0's `gp` moved **backwards**
while it ran — the shell's per-command `region R { ... }` rollback. The rest
follows. The region parked the bump pointer, a timer switch let the background
task allocate its loop closure above the mark, and the rollback freed it — live —
for the next command to overwrite. The task then resumed with `a0` pointing into
reused memory and jumped through whatever now sat at its closure's first word._

_**Sharing the bump pointer between tasks was the bug.** v0.1.192's rule ("gp is
machine state; never switch it") missed the other direction: with a shared heap,
anything that rolls the pointer back frees what the other context allocated
meanwhile. The rule that survives contact is the user-process one, applied inside
a single program: **contexts share `gp` only if they genuinely share a heap, and a
context that uses regions must not.** The scheduler and shell examples now give
each task an arena carved from `machine_scratch` — heap up from the bottom, stack
down from the top, so the out-of-memory check guards each task for free — and
switch every register. `raw_len` (the partner of `raw_base`) went in so a kernel
can partition a window it was handed without hardcoding the runtime's geometry._

_**And v0.1.193's fix had fixed nothing.** Making the handler allocation-free
moved the corruption out of sight, not out of existence: in the shipped shell the
background task's counter froze a few commands in and never advanced again — the
task was dead, resuming into reused memory every slice, and the fault-stepping
handler swallowed the evidence. The falsification test was the counter, probed
between heavy commands: 864, 864, 864. With per-task heaps it climbs monotonically,
**and the original repro passes with the handler allocating** — the rule "a trap
handler must not allocate" is back to being good practice rather than load-bearing._

_Two adjacent holes found on the way, both real:_

- _The dedicated trap stack (v0.1.197) sat **below** `machine_scratch`, so a
  handler allocating while an arena task was interrupted compared a high `gp`
  against a low `sp` and declared the heap exhausted, spuriously. The stack now
  sits above the arenas, where the same check instead **protects** it: an arena
  that grows into the trap stack is refused._
- _The runtime's abort paths (`__oom`, `__raw_fault`, `__pat_fail`) report and
  exit via `ecall` — which, with a kernel installed, vectored to the program's own
  handler; a handler that steps over faults swallowed both ecalls and execution
  fell off the end of the helper into whatever was emitted next. They now take the
  machine back (`csrrw x0, mtvec, x0`) before reporting: a dying runtime owes the
  program nothing, but it owes the person at the terminal a message._

_All six bare-metal examples verified, the background counter climbing, the
self-hosted compiler still byte-identical under its kernel. `dune runtest`
2336/0, ctest 13/13._

---

## v0.1.197 — 2026-08-11

_A third hypothesis for the allocating-handler corruption, also disproved. The
change it prompted is worth keeping anyway: the trap handler gets a stack of its
own._

_Until now the handler ran on whichever task's stack it interrupted. That is a
design smell independent of any bug — it makes the handler's frame size a
constraint on every task's stack, and it means a task with a nearly-full stack
turns any trap into a memory-corrupting event. The trampoline now switches `sp`
to a dedicated 8KB stack in the reserved region once every register is safely
saved, which is what a kernel does and for these reasons. `machine_scratch`
starts above it, so task stacks are unaffected except for being 8KB smaller._

_It does not fix the corruption. Three mechanisms are now ruled out — the
header-before-bump window (v0.1.193), trampoline reentrancy (v0.1.195), and the
handler's stack placement (here) — against a signature that is precise:_

- _a task resumes with `a0` holding a pointer to the **trap save area's window
  block** — a two-word `Raw` value that only the handler ever constructs;_
- _the next closure tail call reads word 0 of it as a code pointer, which is the
  save area's base, and jumps there;_
- _from then on the machine executes its own saved registers as instructions._

_Every write to that `a0` slot comes from the trampoline's own save instruction,
so the value was in `a0` at trap entry, meaning the interrupted code held it —
and the only code that holds it is the handler. Which would be reentrancy, which
the depth check says is not happening. One of those two statements is wrong and
finding out which is the next probe: log the first forty writes to the slot rather
than the last, and see the value's first appearance instead of its aftermath._

_Recorded rather than guessed at. The rule stands and every example keeps it: a
trap handler must not allocate. All six bare-metal examples verified (uart, timer,
sched, shell, user, selfhost — the last still byte-identical to the interpreter),
`dune runtest` 2336/0, ctest 13/13._

---

## v0.1.196 — 2026-08-11

_The self-hosted Mere compiler, running as a user process on a Mere kernel, on a
CPU written in Mere._

```
kernel: running the self-hosted Mere compiler as a user process
(module
  ... 5,224 more lines of WAT ...
kernel: user process exited after 3 syscalls and 3727 ticks
```

_The WAT is byte-identical to what the native interpreter emits for the same
input. It reached the UART through kernel write syscalls, from a process the timer
preempted 3,727 times along the way._

_Nothing new was needed. The compiler image is
[examples/riscv_user_selfhost.mere](../examples/riscv_user_selfhost.mere) — the
contrib self-hosted compiler asked to compile `let x = 10 in x * x + 1` and print
the result, with no idea it is a user process. The kernel is
[examples/riscv_bare_selfhost.mere](../examples/riscv_bare_selfhost.mere), which is
v0.1.194's kernel with a bigger tenant: 24MB for the image, because the compiler's
heap peaks between 14 and 18MB and this backend's allocator never frees. That
measurement, made back in v0.1.186, is why `--ram` exists._

_The tower, bottom to top: a language; a backend of its own that emits RV32IM; a
CPU written in that language to run it; a kernel written in it too, with traps, a
timer, a scheduler and a syscall boundary; and the language's own compiler running
as a process on that kernel._

_v0.1.147 reached the third floor of that and called it the north star. This is
the fifth._

---

## v0.1.195 — 2026-08-11

_Chasing the allocating-handler corruption from v0.1.193. Two hypotheses tested
and disproved, one narrowed to a single instruction, and a permanent diagnostic
for the class._

_The repro is deterministic: the shell with its register-copy loops moved back
**inside** the handler (where they are closures, and a closure is an allocation),
driven by a 33-command session. It stops at exactly the same byte every time._

_Working backwards with the emulator, which is where this backend's debugging
lives:_

- _the guest ends up executing the **trap save area** as if it were code — `mcause`
  2 (illegal instruction), the PC marching forward four bytes per trap because
  the fault path returns `mepc + 4`;_
- _it got there from `jalr zero, 0(t1)` — the tail call this backend emits for a
  closure — with **`t1` holding the save area's base address**;_
- _`t1` was loaded two instructions earlier by `lw t1, 0(a0)`, the code-pointer
  fetch. So `a0` was pointing at the two-word block a `Raw` window is, not at a
  closure: word 0 of that block is the window's base, and the window in question
  is the save area._

_A pointer to the save-area window is a value only the **handler** ever holds. So
some register belonging to the handler ends up restored into a task. That reads
like a reentrancy failure — the save area is one global buffer, so a trap taken
while the handler runs would overwrite the interrupted context with the handler's
own. The trampoline now **counts trap depth** and refuses to nest, printing what
happened and stopping, because with one save area there is nothing left to
resume. It is placed after the register-save loop, since checking any earlier
would clobber a register before saving it — which is the exact bug it exists to
catch._

_**And it does not fire on the repro.** So the corruption is not a nested trap
either. That is worth as much as a positive result: two mechanisms are now ruled
out (the header-before-bump window, fixed in v0.1.193 and not the cause; and
reentrancy, ruled out here), and the failure is pinned to one instruction with a
known-wrong register. What remains unexplained is how a handler-local pointer
reaches a task's register file at all._

_The rule stands and is now enforced by construction in every example: **a trap
handler must not allocate.** The nested-trap check stays regardless — it turns a
whole class of silent corruption into a sentence, which is this project's usual
trade._

_All five bare-metal examples verified after the trampoline change (uart, timer,
sched, shell, user), `dune runtest` 2336/0, ctest 13/13._

---

## v0.1.194 — 2026-08-11

_A user process. A separately compiled, ordinary Mere program running under a
Mere kernel, printing through kernel syscalls, preempted by the timer, and
unaware that any of that is happening._

```
kernel: starting a user process at 8MB
user: hello from a user process
user: I do not know a kernel exists
user: fib 20 = 6765
user: exiting
kernel: user process exited after 9 syscalls and 21 ticks
```

_The user program in
[examples/riscv_user_prog.mere](../examples/riscv_user_prog.mere) is not `--bare`,
holds no capability, names no device and touches no CSR. It calls `print`. That
lowers to the same `ecall` every hosted Mere program on this emulator has always
used — what changed is **who answers**: with mtvec set, an environment call traps
(cause 11) and the kernel in
[examples/riscv_bare_user.mere](../examples/riscv_bare_user.mere) reads fd, buffer
and length out of the register save area and writes the bytes to the UART. Neither
the emulator nor the user program is in that conversation. That is the whole idea
of a syscall boundary, and it is why the user program needs no cooperation: it asks
the machine, and the machine now has a kernel._

_**`--load-base <addr>`** is what makes two programs fit in one address space.
Everything PC-relative in the emitted binary never cared where it lived; the
absolute parts did, and they all went through three places — the globals region,
the stack top, and the assembler's resolution of `la` for string literals and
lambda entries. They now shift together. The kernel says where its user process
goes; the process does not know._

_One thing this got wrong first, and the mistake is the interesting part. v0.1.192
found that `gp` — the heap's bump pointer — must **not** be switched between tasks,
because two tasks in one program share a heap and switching it makes them allocate
over each other. Carrying that rule over to a user process broke immediately: the
kernel resumed with the user's `gp`, its next allocation landed at the user's heap
top, and the out-of-memory check compared that against the kernel's much lower
stack and correctly declared the heap exhausted._

_So the rule is not about tasks at all. **Switch `gp` exactly when the two contexts
do not share a heap.** Two tasks in one program share one; two programs built with
different `--load-base` do not. Both examples now say so, and say why._

_On the emulator side (memu): `ecall` traps to `mtvec` when a kernel is installed
and falls back to the host ABI when none is, and a second image `user.bin` loads at
8MB if the file is there — a bootloader's job, done by the bootloader, since a
kernel with no filesystem has to get its first process from somewhere. The
instruction fetch is guarded now too, which is what made the previous slice's
debugging possible at all._

_A consequence worth noting: any `--bare` program that installs a trap vector must
clear it before returning, or `_start`'s exit `ecall` vectors into its own handler
instead of halting. The timer and shell examples now do._

_Two new tests. `dune runtest` 2336/0, ctest 13/13, parity 84/84._

---

## v0.1.193 — 2026-08-11

_A shell, on a machine with no operating system. And a rule the previous slice
got wrong._

_[examples/riscv_bare_shell.mere](../examples/riscv_bare_shell.mere) reads a line
from the UART, dispatches a handful of commands, and reports on the machine it is
running on: `bg` twice shows a counter that climbed while the shell sat waiting
for a keystroke — nothing yielded to it, the timer took the CPU away and the
handler gave it to the other task. `fault` reads an address the machine does not
have, and the same handler that schedules fields the access fault, counts it, and
steps over the faulting instruction, so a bad command does not take the machine
down. Each command runs inside `region R { ... }`, which is what keeps the heap
flat across a session on a backend whose allocator never frees._

_It needed no new language features. That is the point of the slice, and it is
also the signal that this dogfood has stopped generating pressure._

_**The correction.** v0.1.191 said the trampoline's save-and-restore of `gp` gives
"a region per trap, for free". That is wrong, and this shell is what proved it: a
trap handler that allocates corrupts the program it interrupted. Reproducibly —
three sessions, three corruptions — and cleanly fixed by moving the handler's two
register-copy loops to top level, where they are functions rather than closures
and so allocate nothing._

_Two candidate mechanisms were investigated and neither fully explains it. The
runtime's variable-size allocators did claim a block and write its header
**before** advancing `gp`, which leaves a window where an allocating trap lands
on a block that already has contents; those are reordered here to bump first and
fill after (`__str_concat`, `__str_of_int`, `__substring`, `__strbuf_new` — the
vec allocators were already in the right order). That is a real latent bug and
worth fixing on its own, but it was not the whole story: with it fixed the
corruption still reproduced. Removing the handler's allocation fixes it; so does
not rolling `gp` back. The honest state is that the interaction between a bump
allocator and an involuntary interruption is not yet understood, and the working
rule — **do not allocate in an interrupt handler** — is one real kernels keep
anyway. It is now what the example does and why._

_`dune runtest` 2334/0, ctest 13/13, parity 84/84; the interpreter-vs-emulator
sweep is unchanged at 39 / 38 / 8._

---

## v0.1.192 — 2026-08-11

_Preemptive multitasking. Two Mere tasks, neither yielding, on a machine with
no operating system._

_A context switch turned out to need no new mechanism. The trampoline already
saves the interrupted register set to a known place and restores from that same
place before `mret`, so switching tasks is a memory copy in the middle of a
handler: the save area into the outgoing task's TCB, the incoming task's TCB
back into the save area, and its PC as the handler's result. The scheduler in
[examples/riscv_bare_sched.mere](../examples/riscv_bare_sched.mere) is thirty
lines of ordinary Mere._

_What a bare program could not do was **name** any of it, so five primitives
went in — all narrowing from the machine capability, so none of them hands out
authority the program did not already have. Only coordinates:_

- _`trap_save mach` — the save area, so a handler can reach both sides of a switch_
- _`machine_scratch mach` — reserved RAM the runtime is not using, which is where
  a task stack comes from. A bare program owns no fixed address of its own: the
  heap grows up from 2MB and the stack down from the top, so any address it picks
  is one the compiler is already using. The timer example's first draft learned
  this by sharing a word with a top-level binding._
- _`raw_base w` — a window's base as a number, because a stack pointer is an
  address and the hardware wants the number. Not authority: touching anything
  still needs a window._
- _`closure_code f` / `closure_env f` — a task IS a closure, so starting one means
  building a context whose PC is its code and whose a0 is its environment. ABI
  knowledge, which a kernel legitimately has._

_One word must **not** be switched, and finding out why is the interesting part:
`gp`, the heap's bump pointer. Save and restore it per task and two tasks
allocate over each other, each rolling the pointer back to where it stood when it
last ran. The heap is machine state, not task state. That is a real collision
between this language's memory model and concurrency, and the answer here — share
the bump pointer, leave the word alone across a switch — is the simplest one that
is correct. A per-task heap would be the other, and it is not needed yet._

_Also: the RV32I backend had `print_int` but not `print_bool`, which the parity
file added in v0.1.190 immediately caught by being the one file `-rv` refused.
It lowers the way LLVM and Wasm do it, as `print` of a literal._

_Two new tests. parity 84/84, ctest 13/13, `dune runtest` 2334/0. The
interpreter-vs-emulator sweep of `test/parity` is 39 identical / 38 refused / 8
mismatching — one better than last slice, since print_int_bool now runs there
too._

---

## v0.1.191 — 2026-08-11

_The machine takes traps, and a Mere closure services them. A timer interrupt
arrives while the program is doing something else._

_A trap handler cannot be an ordinary function: it is entered with every
register live and it leaves with `mret`, not `ret`. The tempting move is to give
the language a `naked fn` or an interrupt attribute. That is not needed —
codegen already emits `_start`, so it can emit the trampoline too, and the user
writes plain Mere._

_The harder question was how a handler gets the machine capability. It needs one
for anything useful (a context switch is a memory copy), and an interrupt has no
caller to hand it anything. So the handler is **registered rather than named**:
`set_trap_handler (fn cause -> ...)` takes a closure, which captures whatever it
needs. The trampoline stores it, points mtvec at itself, and calls it with
mcause; the result is the PC to resume at. Everything else the handler might want
is a `csr_read` away — mepc, mtval — so nothing has to be packed into a tuple,
which would mean allocating inside a trap._

_`mscratch` holds the save area's address, because at trap entry there is no
free register to build one in — which is what that CSR exists for. `gp`, the
bump pointer, is saved and restored with the rest, so whatever the handler
allocated is reclaimed when it returns: a region per trap, for free. The
corollary, worth stating, is that a handler must not leave an allocated value
somewhere that outlives it._

_**(v0.1.193: that last paragraph is wrong. An allocating handler corrupts the
program it interrupted, reproducibly. The rule is that a trap handler must not
allocate at all — see v0.1.193.)**_

_On the emulator side traps vector to mtvec with mepc / mcause / mtval set and
MIE moved into MPIE. Three causes so far: an unimplemented instruction (2), a
load or store past the end of RAM (5 / 7), and the timer (0x80000007). The
access faults are an improvement in their own right — an address past RAM used
to take the **emulator** down with a Mere "index out of bounds", reporting the
host's problem instead of the guest's. A guest with mtvec still zero halts, as
before, rather than jumping to address 0._

_The timer is a CLINT with mtime and mtimecmp in the MMIO region. mtime advances
once per instruction: a clock in units of work done, which is what a
deterministic emulator can honestly offer and enough for a scheduler tick. The
interrupt is taken between instructions._

_[examples/riscv_bare_timer.mere](../examples/riscv_bare_timer.mere) arms it and
spins. The ticks arrive anyway, which is the mechanism preemption is made of:
once a handler runs without the interrupted code's cooperation, a scheduler is a
matter of what that handler chooses to return._

_The example's first draft kept its tick counter at `0x200000` and quietly shared
a word with a top-level binding — that address is where globals live. A bare
program owns no fixed RAM: the heap grows up from 2MB and the stack down from the
top. The handler's state is an ordinary Mere cell it captures instead, which is
both correct and the better demonstration._

_Three new tests (twenty-one on this backend). parity 84/84, ctest 13/13,
`dune runtest` 2332/0._

---

## v0.1.190 — 2026-08-11

_`print_int` and `print_bool`, which the reference has claimed for every backend
since Phase 22 and which only the interpreter had._

_Found while smoke-testing the RV32I work: `let f = fn n -> let _ = print_int n
in n;` would not compile on the **C** backend. Not a shadowing or value-position
subtlety — codegen_c had no arm for the name at all, so it fell through to the
closure path and emitted a call to an undefined `mu_print_int`. The refusal then
arrived from clang, as "use of undeclared identifier", about a symbol the user
never wrote. LLVM and Wasm at least said what they meant ("no lowering yet"),
though LLVM's message named its scope as "interp + C", which was not true
either._

_So a documented builtin worked in one of four places, and the one that failed
worst failed at the wrong layer. All four now agree. C prints through `printf`
(`%lld`, matching its int width) and `puts` for the bool. LLVM and Wasm route
through the `str_of_int` they already had, so neither needed a new runtime call
or host import — `print_int x` becomes `print (str_of_int x)` at emit time. That
also needed `print_int` added to each one's use-scan, since the helper
`@show_int` / `$show_int` is only defined when something registers it: exactly
the v0.1.42 gap, one level further in._

_`test/parity/print_int_bool.mere` keeps the four in step over zero, negatives
and a bool from a comparison. parity 84/84, ctest 13/13, `dune runtest`
2329/0._

_The reference line that claimed all this now says what actually happened._

---

## v0.1.189 — 2026-08-11

_Machine CSRs, and a non-blocking byte of stdin so a UART can have a receive
side._

_**CSRs.** `csr_read` / `csr_write` lower to CSRRS-from-x0 and CSRRW-to-x0, and
the register number has to be a literal — it is a 12-bit field of the
instruction, so a computed one has nowhere to go, and saying so beats emitting
something that reads a register nobody asked for. They are `--bare` only: a
trap vector means nothing under a host. Unlike raw memory they are **not**
behind a capability, and that is a decision rather than an oversight — a CSR
has no base and length to narrow, and the hardware already has machine /
supervisor / user mode to separate a kernel from a user process. Duplicating
that in the type system before there is a user mode to protect would be
speculative._

_The disassembler had been rendering every CSR instruction as `ebreak`, because
it only knew `inst = 0x73`. It now decodes the six CSR forms plus `mret` and
`wfi`, which matters more than it sounds: this backend's debugging story is
reading its own listings._

_**A receive side.** The plan for the UART's input half was "the emulator reads
host stdin with `read_key`", and that does not work: `read_key` blocks. A CPU
polling a line-status register cannot stop the machine to find out whether a
byte is waiting — and once there are timer interrupts it will have other things
to do while nothing is arriving. So the dogfood forced a new builtin instead:
**`stdin_byte : unit -> int`**, one byte or -1 when nothing is ready, on the
interpreter and the C native backend (select with a zero timeout, so it leaves
stdin's flags alone and composes with `tty_raw` and with a plain pipe alike)._

_With that, [examples/riscv_bare_echo.mere](../examples/riscv_bare_echo.mere)
echoes what you type through the UART and stops at `q` — polling the status
register, reading the data register, all through the window capability `main`
was handed, with no host syscall anywhere in it. That is the last piece the
shell needs._

_Four new tests (eighteen on this backend). parity 83/83, ctest 13/13,
`dune runtest` 2329/0._

_Recorded while here, unrelated and pre-existing: on the **C** backend
`let f = fn n -> let _ = print_int n in n;` does not compile — the builtin ends
up in value position and the emitted C calls an undefined `mu_print_int`. It
reproduces on the pre-session compiler, so it is not from this arc; `print` on a
str refuses at codegen instead. Worth its own slice._

---

## v0.1.188 — 2026-08-11

_Bitwise operators on the RV32I backend, and the INT_MIN bug they found._

_The UART example from the previous slice had to read a status bit with
`/ 32 % 2`, because this backend had no `bit_and`. A device driver is mostly
masks and shifts, so that was the next thing in the way. All six lower now:
AND / OR / XOR as R-type, or the I-type form when the operand is a small
literal, `bit_not` as `xori -1`, and `bit_shl` / `bit_shr` as SLL / **SRA** —
arithmetic, because `bit_shr` is documented as floor division by 2^n on every
backend._

_Shift counts of 32 or more needed a decision. RV32 shifts use only the low
five bits of the count, so a bare SLL would quietly make `bit_shl x 33` mean
`x << 1`. What the other backends produce, read back as 32 bits, is zero for a
left shift and the sign bit for a right shift, so that is what this emits:
folded when the count is constant, and three extra instructions (or a branch)
when it is not. A silently different answer was not on the table._

_Then `bit_shl 1 31` printed `-./,),(-*,(`._

_Not a shift bug — `str_of_int` and `print_int` both began by negating a
negative value to make it positive, and 0x80000000 negated is still
0x80000000. Every remainder after that came out negative and `'0' + negative`
is punctuation. Both helpers now go the other way: make the value **negative**
(negating a positive is always safe) and take each digit as `-(x % 10)`. So
INT_MIN prints. This had been latent since the backend's first slice; nothing
before now had produced 0x80000000, because nothing before now could shift._

_The bitwise builtins take three files off the interpreter-vs-emulator sweep's
"refused" list. One joins the matching set; the other two ask for integers
wider than 32 bits (`int64_bitwise` shifts 1 by 40, and `riscv_core` is the
RV32I emulator itself, which needs headroom above 32 bits before masking), so
they cannot match on a 32-bit target and are recorded as such. The sweep now
reads 38 identical / 38 refused / 8 mismatching._

_Three new tests. parity 83/83, ctest 13/13, `dune runtest` 2325/0. The UART
example reads its status bit with `bit_and` now._

---

## v0.1.187 — 2026-08-11

_Raw memory, as a capability rather than an ambient builtin. `mere -rv --bare`
hands a program the machine and it writes to a UART._

_A kernel needs to reach hardware, and this backend's answer so far was one
builtin per device with the address baked into codegen: `fb_set` stores to the
framebuffer, `key` loads from the key register, `present` ends a frame. Adding
a UART, a timer and an interrupt controller that way means a compiler change
per device, which is the opposite of what a dogfood is for — the kernel would
teach the language nothing. The alternative that fits what this language
already says about itself (README: effects are capability values you pass) is
to make the address space a value._

_A **`Raw`** is a window onto physical memory: a base and a length. It is
opaque, nothing constructs one, and there is no function that mints one — the
only source is the argument `--bare` hands to the program's top-level `main`,
and `raw_window` can only narrow. Offsets are relative to the window, so a
driver holding a UART window cannot express an address outside it. All three
ways out are closed and each fails differently: forging one from ints is a type
error, widening one faults at construction, and an offset past the end faults
at the access._

_So this reads as a promise rather than a hope:_

```
let putc = fn (uart: Raw) -> fn (c: int) -> raw_poke8 uart 0 c;
```

_`putc` can touch the UART and nothing else — not the heap, not the stack, not
another device — and that is visible in its signature instead of being a claim
about its body and every body it calls. That is the whole argument for a value
over an ambient builtin._

_The bounds check is not free and not optional: a window's length is a runtime
field, so there is nothing to fold at compile time even when the offset is a
literal. Three instructions on an MMIO poke buys a guarantee that holds, which
is the better trade than a nominal one._

_Device MMIO now sits above any RAM — the UART's data register is at
`0x10000000`, the address QEMU's `virt` machine uses, so a driver written today
is not inventing a private convention. `--ram` is capped so RAM can never reach
it, which means a device address does not move when the RAM size does. (The
fantasy console's framebuffer and keys predate this and still live in the
reserved top of RAM; they move with `--ram` and will migrate when that demo is
next touched.)_

_`--bare` also refuses `print` / `print_int` / `print_no_nl` / `print_err`:
those lower to the emulator's write syscall, which no real machine answers, and
a bare program that depends on the courtesy would break the moment it left the
emulator. A UART window is three lines away — see
[examples/riscv_bare_uart.mere](../examples/riscv_bare_uart.mere), which prints
through one and reads the 16550 line-status register back._

_Every other backend refuses these names, because there is no honest physical
address in a hosted process. The C backend had to be taught to: without an arm
of its own the raw_\* names fell through to the closure path and emitted a call
to an undefined `mu_raw_poke8` plus an unknown `Raw` C type, so the refusal
arrived from clang as "type specifier missing" — loud, but about the wrong
thing. LLVM and Wasm already refused._

_Five new tests, fourteen on this backend now. parity 83/83, ctest 13/13,
`dune runtest` 2322/0; the interpreter-vs-emulator sweep of `test/parity` is
unchanged at 37 / 41 / 6._

---

## v0.1.186 — 2026-08-11

_A RAM size instead of three hardcoded addresses, and the self-hosted compiler
runs on the RV32I emulator again._

_v0.1.185 ended by reporting that the self-hosted compiler no longer fits on
this backend. The reason it did not fit was not really its appetite: the stack
top, the print scratch buffer and the fantasy-console framebuffer were three
immediates baked into codegen, which pinned the heap's ceiling at 0x7E0000 and
gave every program on this backend the same 5.86MB no matter what it was doing._

_They now derive from one number. The top 128KB of RAM holds the scratch buffer
and the MMIO; the stack starts just below that and grows down; the heap grows up
from 2MB; everything between the two growing ends belongs to them. At the
default 8MB every address comes out exactly where it has always been, so an
emulator sized for the old layout needs no change. `mere -rv --ram <MB>` (and
`-rvs --ram`) raises it._

_With that, the measurement the previous slice could not make: the self-hosted
compiler's heap peaks somewhere between 14 and 18MB — it fails at `--ram 16`
and completes at `--ram 20`. At 20MB it compiles `1+2` on the Mere-written
RV32I emulator and emits WAT byte-identical to the native interpreter. The
tower from v0.1.147 stands again, and this time the requirement is written down
rather than implied: a binary says how much RAM it wants, an emulator is told
the same number, and a mismatch fails loudly at the first allocation past the
limit instead of corrupting a frame._

_The emulator side of that (a RAM size argument, and dropping the 100M
instruction budget the compiler ran past) lives in the memu project, not here.
Two tests lock the layout: the default still puts the stack at 0x7E0000, and
`--ram 32` moves it to 0x1FE0000. `dune runtest` 2317/0; the
interpreter-vs-emulator sweep of `test/parity` at the default size is unchanged
at 37 identical / 41 refused / 6 mismatching._

---

## v0.1.185 — 2026-08-11

_Three holes in the RV32I backend, found by asking what a program that never
returns would need._

_The next dogfood for this backend is a bare-metal kernel: a scheduler, a trap
handler, a shell. Every one of those is a loop that never ends, and iteration
here is recursion — explicitly, and also under `while`, which the parser
desugars to a tail-recursive local closure. So the first question was how long
a recursion this backend can actually sustain, and the answer was: not long,
and it does not say so. A zero-allocation tail-recursive counter completed at
500,000 and died silently at 1,000,000; raising the emulator's instruction
budget twentyfold did not change that, so it was the stack, not the clock. A
`while` loop, which pays for a closure frame per iteration, died at 300,000._

_**Tail calls.** A saturated call in tail position now tears the frame down
first and jumps, so the callee returns straight to our caller and the stack
stays flat. The tail-position bookkeeping mirrors codegen_wasm's
`wasm_tail_pos` (which lowers to `return_call`): compile_expr clears the flag
for every subexpression and the cases whose value IS the enclosing value —
if branches, let bodies, match arms, annotations — put it back. Direct calls
become `j u_f` instead of `jal ra, u_f`; the closure form, which is the shape a
local `let rec loop = fn ...` and every desugared `while` actually take,
becomes `jalr x0` on the code pointer. Calls with nine or more arguments keep the old path: args 9+ travel on
the caller's stack, which a teardown would drop. The counter now runs
10,000,000 iterations in constant stack._

_**Regions.** `region R { ... }` compiled to its body and nothing else — the
comment said "no reclamation" and meant it. `gp` is the only allocation state
on this backend, so the fix is the one Wasm already uses on `__lang_bump`:
park it on entry, roll it back at the closing brace. Eight rounds of 100,000
allocations inside a region now complete with a flat heap; the same program
without the region reports exhaustion. The body is deliberately not in tail
position — a tail call out of a region would skip the rollback._

_A region also could not call anything. `vars_in`, which decides
which top-level functions are reachable and therefore emitted, had no
`Region_block` case, so a function called only from inside a region was never
emitted and assembly died with `undefined label u_f`. Two lines reproduce it:
`let f = fn x -> x + 1;` and `region R { f 41 }`. It stayed hidden because a
region body of nothing but builtins resolves fine. `free_vars_of` had the same
gap, which would have dropped a capture._

_**Heap exhaustion.** The heap grows up from 2MB and the stack grows down from
0x7E0000 with nothing between them, and when they met the bump pointer
overwrote a live frame's return address with whatever it was allocating — the
program then jumped into the middle of a string. No message, no exit code, just
an emulator reporting a wild load. Every bump now checks `bgeu gp, sp` and
lands on `__oom`, which prints and exits 3._

_That check immediately reported something. The self-hosted compiler, compiled
with `-rv` and run on the Mere-written RV32I emulator, now says it is out of
memory — and with the check patched out it dies the old way, on a wild load, so
this is not a regression from this slice. The self-hosted codegen's output has
grown about a hundredfold since that demo was first verified (a five-line input
now emits ~5,200 lines of WAT, nearly all of it fixed prelude), and building
that with `++` on a bump allocator that never reclaims needs far more than the
5.86MB this memory map leaves. Recorded, not fixed: it wants a configurable RAM
size and a memory map that separates the MMIO region from the heap's path,
which is the same work the kernel needs._

_This backend had **zero** automated coverage — the region bug was a hard crash
that nothing in the suite would have caught. Seven tests now assert on the
emitted listing, so they lock the instruction actually chosen (`j` vs `jal`,
the bump park/restore, the heap check) rather than just that codegen ran.
parity 83/83, ctest 13/13, `dune runtest` 2315/0. A differential sweep of
`test/parity` through the
interpreter and through `-rv` + the emulator: 37 identical, 41 rejected by the
backend as unsupported, 6 mismatching — byte-for-byte the same three numbers
and the same six files before and after this slice._

---

## v0.1.184 — 2026-08-11

_`to_json` on LLVM, and a parity harness that counts what it did not check._

_This one is not a dogfood, and saying so is the point. Nothing forces `to_json`
on LLVM: everything native in this repo goes through C, and no app names LLVM.
Inventing an app to justify the capability would invert the discipline the
browser dogfoods have been run on all week — apps force capabilities, not the
reverse._

_What justifies it is coverage, and coverage is a number. `scripts/parity.sh`
treated a clean refusal as a passing row, so a backend that checked nothing said
so in a word buried in a line. It now tallies per backend and names the cases:_

```
unchecked on llvm: 7 of 83 (refused at emit time)
    nested_tuple
    of_json_composite
    ...
```

_Five of LLVM's seven were the JSON family, and that number grows with every
test that touches `to_json` — `contrib/schema` being a library means future apps
using it would go unchecked there too._

_`to_json` turned out to be `show` with different literals: the same structural
walk, the same per-type functions, the same recursion. So it is not a second
emitter but one with a mode — `emit_struct_fn ~json:true` — which is also the
arrangement that keeps them from drifting. The differences are all shape: `[..]`
for a tuple, `{"f":..}` for a record, `","` rather than `", "` in a list, a
quoted name for a nullary constructor and a single-key object for a carrying
one, and `null` for unit. Option is the one real special case — JSON spells it
as the value or `null`, not as `{"Some":4}` and `"None"` — and getting that
wrong was the last diff before the backends agreed._

_LLVM's blind spot is 7 → 6, and every remaining case is `of_json`. That stays
deferred: decoding needs a JSON parser written in the target language, C and
Wasm each have their own hand-written one, and nothing rides on a third. The
number is in the harness now, so the cost of leaving it is visible rather than
argued about._

_parity 83/83, ctest 13/13, dune runtest 2308/0._

---

## v0.1.183 — 2026-08-11

_`of_json_like`: the target type from a witness value, so a decoder can live
inside a polymorphic function — and `contrib/schema`, which is what that was
for._

_`of_json` reads its target type off the call node. At a use site with an
annotation that is exactly right; inside a generic helper it is a variable, and
the interpreter has no runtime types to resolve it with. The monomorphizing
backends managed — with v0.1.182's fix a generic setter compiled and ran
correctly on C — so a program could be compiled and not interpreted, which is
the wrong kind of split for a language whose parity harness treats the
interpreter as the reference._

_A witness closes it. `of_json_like : 'a -> str -> 'a` takes a value of the
target type; the interpreter reads the type off its runtime shape (a record
carries its type's name, a constructor gives one through `Typer.constructors`)
and the compiled backends read it off its static type, which is the same
variable the result unifies with. `of_json_opt_like` is the non-crashing form,
and the one a generic setter actually needs: it tries a shape and finds out
whether it decoded. The witness is never an imposition — replacing one field of
a record means holding the record._

_`contrib/schema/reflect` is the payoff: `schema_fields` / `schema_text` /
`schema_with` over any record, from the name-keyed view the compiler already
synthesises for `to_json`. `examples/claims` had carried a per-record copy of
exactly this since v0.1.176 and now imports it, so a form generated from a
record declaration is a library rather than a trick in one app._

_Two collection gaps surfaced while wiring it. `collect_mono_variant_instances`
walked fn signatures and not fn bodies, so `person option` — produced by
`of_json_opt_like` inside a generic setter whose own signature never mentions an
option — was never registered and the emitted C named an undeclared struct. And
the new collector arms called `ty_tag` before checking the type was concrete,
which inside the generic skeleton it is not._

_A polymorphic record still needs the annotation: a value carries its type's
name but not its type arguments, so a witness cannot describe `Box[int]`. LLVM
is unchanged — it has no `to_json` at all, which is a separate gap._

_`test/parity/schema_reflect.mere` runs the one implementation over two record
types. parity 83/83, ctest 13/13, dune runtest 2308/0, claims browser check
17/17 against the native server._

---

## v0.1.182 — 2026-08-11

_The monomorphization bug, found and fixed. `specialize_single_use_local_fns`
read "one concrete use" as "used at one type"._

_Three slices ago this was a silent miscompile; two ago it became a named
refusal; here it is a working program. The cause is one line of judgement in a
codegen pass._

_`specialize_single_use_local_fns` fixes a local polymorphic fn's type in place
when its body contains exactly one concrete use of it — a good optimisation,
since a fn used at one type needs no multi-instantiation machinery. But
`find_all_concrete_arrows_in` only reports the uses it can already read, and a
use sitting inside a polymorphic function is not concrete **yet**:_

```mere
let hold = fn (v) -> (v, v);
let mk = fn (v) -> (hold v, hold 1);
```

_`hold 1` is concrete. `hold v` is not, and only becomes so once `mk` is
instantiated — at which point it may be a different type. The pass counted one
arrow, unified `hold`'s definition with `int`, and the `str` instantiation had
nothing left to unify with, so it was emitted with the `int` body. It now also
requires that the body contain no unresolved use of the name. False only when a
use genuinely cannot be read yet, so a fn that really is used at one type still
specializes._

_How it was found is worth recording, because reasoning about it was wrong
three times. Instrumenting `generalize` showed `hold` correctly generic with one
quantified variable. Instrumenting the skeleton collection showed it arriving at
codegen as `int -> (int * int)`. Removing each post-typing pass in turn changed
nothing. Watching the specific type variable's binding site printed
`Loc.dummy` — which is not a source location at all, and which only codegen
uses._

_The payoff: `contrib/state/store` uses `contrib/state/cell` again. It had been
writing its three one-slot vecs out longhand since v0.1.178 for exactly this
reason — a store instantiated at two state types calls `cell_new` at a type
derived from S and at plain `int` for its token counter — so the module that
names the trick can now use it._

_`test/parity/poly_helper_fixed_and_free.mere` has outlived two expectations
(wrong, then refused, now `1s2` on all four backends) and is kept because the
shape is easy to break again. parity 82/82, ctest 13/13, dune runtest 2308/0,
claims browser check 17/17 against the native server, and all five browser
clients rebuild._

---

## v0.1.181 — 2026-08-11

_Two corrections and a better repro. No new capability._

_The monomorphization repro from v0.1.179 used `vec_new` and read as if mutable
containers, the narrow value restriction or the region model were involved.
None of them are. Reduced further, `hold` allocates nothing:_

```mere
let hold = fn (v) -> (v, v);
let mk = fn (v) -> (hold v, hold 1);   // parameter-derived AND fixed
let (a1, a2) = mk 1 in
let (b1, b2) = mk "s" in ...
```

_Three neighbouring shapes compile and run — one instantiation of `mk`, `hold`
called only at the parameter-derived type, and `hold` used directly at two types
— so it is the combination and nothing smaller.
`test/parity/poly_helper_fixed_and_free.mere` now holds that version._

_The search for where the skeleton gets fixed narrowed without landing.
`generalize` is called on `hold` and `instantiate` substitutes without mutating,
so use sites cannot be reaching back to the definition — and yet by the time
codegen takes its pristine clone the skeleton reads `int -> (int * int)` while
`mk` beside it is still `'a -> (('a * 'a) * (int * int))`. Whatever fixes it
runs before codegen. Recorded in the test rather than guessed at._

_The second correction is to v0.1.180's memory measurement, and is written into
that entry: two samples read as a leak in `contrib/store/kvlog`, and nine
thousand requests show RSS oscillating (4528, 3568, 5840, 7536, 6656, 8272 KB)
rather than climbing. That is malloc churn as the region takes and returns
blocks. The native HTTP arena is doing its job; there is no kvlog leak to fix,
and the item is withdrawn rather than carried._

_parity 82/82, ctest 13/13, dune runtest 2308/0._

---

## v0.1.180 — 2026-08-11

_The native HTTP runtime gets the four externs a middleware stack needs, so
`examples/claims` runs on both hosts from the one source._

_It implemented six. contrib/http's middlewares need four more:
`http_current_status` and `unix_time` for access_log, `http_arena_mark` for the
per-request arena, `http_send_file` for static. A server with a middleware stack
could therefore be built for the Node host and not the native one — which is
half of "the same source runs on both", and the half nobody had checked because
the browser dogfoods only ever ran the Wasm host._

_All four are in. The arena checkpoint is the interesting one: the C region is a
chain of malloc'd blocks with a bump pointer, so a mark records the block chain
and the pointer, and the release frees every block newer than the mark and winds
the pointer back. It runs after the response has gone out on the socket, not
before, because the body it just wrote lives in that arena. The checkpoint is
taken where the request began rather than wherever the handler calls
`http_arena_mark`, so the request line and the body copy — made by the accept
loop before the handler is entered — are inside it too. Still opt-in: nothing is
released unless a handler asks._

_`http_send_file` writes the file straight to the socket without it passing
through a Mere `str`, which is the point of that binding — a str is
NUL-terminated and a file is not — and tells the accept loop not to write a
second response after it._

_Measured on the native build: **116 KB reclaimed per request**, with no new
blocks allocated on the paths that fit, so the region stays in its first 4 MB.
Two thousand 404s in a row moved RSS 3920 → 1920 KB, i.e. down._

_(Correction, made while writing v0.1.181: this entry first read a second
measurement — 1920 → 6336 KB over two thousand requests that read the kvlog —
as locating a leak in `contrib/store/kvlog`. Sampling nine thousand requests
instead of two thousand shows RSS oscillating rather than climbing: 4528, 3568,
5840, 7536, 6656, 8272 KB. That is malloc churn as the region takes and returns
blocks, not a per-request leak, and two samples were not enough to say which.)_

_`examples/claims/browser_check.mjs` passes 17/17 against the native server,
unchanged from the Wasm host. parity 82/82, ctest 13/13, dune runtest 2308/0._

---

## v0.1.179 — 2026-08-11

_The monomorphization gap v0.1.178 recorded without a repro, isolated to seven
lines — and made loud, which is as far as this slice goes._

_The shape, self-contained and with no imports:_

```mere
let hold = fn (v) -> let c = vec_new () in let _ = vec_push c v in c;
let mk = fn (v) -> (hold v, hold 1);      // parameter-derived AND fixed
let (a1, a2) = mk 1 in
let (b1, b2) = mk "s" in ...
```

_A polymorphic helper called at both a parameter-derived type and a fixed one,
inside a function that is itself used at two types. Written `(hold v, hold v)`
it is fine, and used directly at two types it is fine; it is the combination._

_What it produced: `hold` monomorphized into an `int` copy and a `str` copy,
both declarations with the right signature and **both bodies with the `int`
one's operations** — a `mere_vec_str*` function calling `mere_vec_int_push`. Not
a wrong answer, no answer, and only when the C compiler saw it, with a message
about pointer conversions naming nothing in the source._

_The mechanism, traced: codegen keeps a pristine clone of each polymorphic
skeleton and unifies a fresh copy with every instantiation's arrow. That unify
was wrapped in `try ... with _ -> ()`, and when it fails the spec's body belongs
to another type. It cannot fail while the skeleton is genuinely polymorphic —
and here it is not. Instrumenting the clone showed the typer hands codegen
`hold` already fixed at `int -> Vec[__heap, int]`, while `mk` beside it is still
`'a -> ...`. Written `(hold v, hold v)` the skeleton arrives polymorphic._

_All three compiled backends now refuse instead of emitting, with a message that
names the function, the arrow it cannot take, and the type it is stuck at. That
turns a wrong program into a named one; it is not the fix. The fix is upstream
of codegen, in whatever fixes the skeleton before it is cloned, and
`test/parity/poly_helper_fixed_and_free.mere` will change from UNSUP to a real
answer when that lands._

_This is why contrib/state/store writes its three one-slot vecs out longhand
instead of using contrib/state/cell: a store instantiated at two state types
calls `cell_new` at a type derived from S and at plain `int` for its token
counter. The module that names the trick does not get to use it, and now says
why. parity 82/82, ctest 13/13, dune runtest 2308/0._

---

## v0.1.178 — 2026-08-11

_A page with two views, so that a watcher's lifetime becomes a question — and
the answer that `drop type` cannot give._

_`examples/claims` grew a tab bar over one store: a Form view that builds the
generated controls, the line rows and the actions, and a read-only Summary view.
Switching drops the old view's DOM wholesale. Dropping the nodes did not drop
the watchers, because contrib/state had no way to take one back, so **three
round trips between the tabs left eleven watchers running, nine of them painting
into nodes no longer in the document.** The counter in the tab bar is how that
became visible at all._

_`store_watch` now returns a token and `store_unwatch` takes it; the app
collects a view's tokens and releases them on close. **11 → 2, and constant
however far the user navigates.**_

_The language question this was chosen to ask has a negative answer, which is
worth having. Mere's one mechanism for enforced release is a `drop type` bound
by `with`, whose `close` runs at scope end — and **a subscription's lifetime is
not the scope that created it.** The view is built in one event and torn down in
another, so by the time `with` would close the handle the view has not even been
shown. A drop type also cannot be placed in a region, which is where the watcher
list lives. So releasing stays a convention, recorded in contrib/state's README
rather than papered over._

_Two compiler findings on the way. A binding called `entry` did not compile on
LLVM at all: values and basic-block labels share one namespace there and every
emitted function opens with a block called `entry`, so a parameter of that name
claimed the slot first — "unable to create block named 'entry'". Not a wrong
answer, no answer, from a name nothing warns about; `entry` is the obvious name
for an element of an association list, which is how it turned up.
`llvm_safe_local` renames the parameter, since the `entry:` label is written
into every hand-authored runtime blob in that file.
`test/parity/reserved_local_entry.mere` holds it across the shapes that emit a
parameter separately — top-level fn, lifted inner fn, closure adapter._

_And the store could not use contrib/state's own `cell`: a store instantiated at
two different state types puts `cell_new` at three types derived from S, and
that shape does not survive monomorphization on C or LLVM. The builtin vec does,
so the module that names the trick writes its three slots out longhand. Recorded
in the source; a minimal repro is not yet isolated._

_parity 81/81, ctest 13/13, dune runtest 2308/0, claims browser check 17/17 —
including that three round trips between views leave no watchers behind._

---

## v0.1.177 — 2026-08-11

_Stage 4 of the shared-schema dogfood: change the schema in ways other than
adding a `str`, and see what the derived machinery does. It found a hole in the
mechanism and a soundness hole underneath it._

_The mechanism first. `claim_with` took the JSON shape to write back from the
shape already there, which is exact except for an absent optional — `null`
cannot say what it would have held. The first version guessed "string" and named
the two fields that needed clearing, and adding a `seat: int option` to the
record broke setting it: the guess produced a string and the decode failed.
Where the value cannot say, ask the decoder instead — try the shapes in order
and keep the first that survives `of_json_opt`. Blank text tries `null` first,
which is how an optional is cleared without anything knowing which fields are
optional. All four cases now behave: an optional `str` and an optional `int`
clear to `None`, a required `str` blanks to `""`, a required `int` to `0`, and
the hardcoded field names are gone._

_Underneath it: the probe set every field from text, including the variant-typed
`status`, and `"7"` was accepted. The interpreter's decoder built a nullary
constructor from whatever string arrived without asking whether the variant had
a case by that name, so `of_json_opt` returned `Some` holding a value outside
its own type, which `to_json` then printed straight back out. Both compiled
backends answered `None` — the reference the parity harness compares against was
the one in the wrong, which is why nothing had caught it. The object form was
checked for existence but not ownership, letting a payload case of an unrelated
variant through; `constr_info.type_name` closes both, and a case of this variant
arriving in the wrong shape (`"Rejected"` as a bare string when it carries a
payload) is refused too._

_`test/parity/of_json_variant_tag.mere` holds it and fails without the fix. It
took a dogfood that round-trips a variant field through a form to surface, which
is the same shape as v0.1.175's finding: the boundary bugs live where a value is
only ever decoded. parity 80/80, ctest 13/13, dune runtest 2308/0, claims
browser check 14/14._

---

## v0.1.176 — 2026-08-11

_Stage 2 of the shared-schema dogfood: the form is the record._

_The plan was to let the app pick the mechanism rather than choose one in
advance, and the app picked one that needs no language change at all. A record
already has a total, name-keyed view of itself — the one the compiler
synthesises for `to_json`. Reading it back gives the field names in declaration
order, and replacing one key and decoding gives a setter. `claim_fields` /
`claim_text` / `claim_with` are that, in about forty lines of schema.mere, and
the controls on the page are built from the list at startup. index.html now has
a `<div id="form">` and no field markup._

_Measured the same way as stage 0, by adding a `cost_center: str` field:_

| | stage 0 | stage 2 |
|---|---|---|
| `type claim` | edit | edit |
| `blank_claim` | compile error if omitted | compile error |
| a rule + `claim_problems` | silent | derived |
| the field table in app.mere | silent | gone |
| index.html markup | silent | generated |

_Two edits, in one file, and the compiler forces the second. **Silent sites 3 →
0.** Checked rather than assumed: adding the field and changing nothing else
puts a control labelled "Cost center" on the page and round-trips its value to
storage. `claim_problems` is derived too — it walks the same field list and
applies `rule_for`, so a rule is registered in one place instead of two._

_Two mechanisms were considered and rejected on evidence. A build-time
generator over `contrib/parser` foundered on the parser itself: the self-hosted
parser has no expression-level record literal, field access or record update
(`ERecordLit` and friends are declared in ast.mere and never constructed), so it
cannot parse a schema file that also contains rules — the prerequisite is larger
than the generator. Compiler-synthesised derive was not needed once the JSON
view turned out to be enough._

_Two things this does not fix, both named in the source. `of_json` is not
polymorphic — `to_json` is, but `of_json` is directed by an annotation at the
call site, so `claim_with` has to name `claim` and there is one copy per record
type. And `rule_for` still ties a field name to its rule by hand; nothing in a
declaration can say which rule judges which field, but nothing checks the names
either._

_`examples/claims/browser_check.mjs` covers what a dump cannot: that a generated
`<input>` behaves like one, that leaving it runs the rule the schema associates
with its name, and that the server's own refusals land in the generated error
slots. 14/14 in Chrome. parity 79/79, ctest 13/13, dune runtest 2308/0._

---

## v0.1.175 — 2026-08-11

_Stage 1 of the shared-schema dogfood: a type reachable only as another type's
field is still a type the C backend has to declare._

_The C backend decides which structs to emit by walking what the program
mentions — the expression tree and the function signatures. Neither walk
descended into a record declaration's field types, so:_

```mere
type item = { name: str };
type f    = { title: str, items: item list, note: str option };
```

_left `item`, `list_item` and `option_str` undeclared while the emitted code
referred to all three. `unknown type name 'list_item'`._

_Two walks were short, and both are fixed the same way. `collect_record_names`
now follows a record's field types when it registers it, so a record reachable
only as another record's field element gets declared; and
`collect_mono_variant_instances` walks monomorphic record declarations the way
it already walked monomorphic variant declarations, so container
specializations reachable only as field types get registered. `seen` is set
before recursing, so a self-referential record terminates._

_This had been latent since records and `of_json` first coexisted, because a
program that builds one of those values anywhere registers the type on the way
past — and, as the test found the hard way, so does taking one apart:
mentioning `Some` in a pattern is enough. The failure needs container-typed
fields that are **only ever decoded**, which is exactly what a program looks
like once the schema is shared and the codec is synthesised, since `of_json`
becomes the only producer. examples/claims was written that way and found it;
`test/parity/of_json_field_only.mere` holds it, and reads only the scalar
fields on purpose — an earlier draft called `list_len` and matched `Some`, and
passed on the broken compiler._

_examples/claims now emits and compiles as C; what stops a native build is only
the two HTTP externs the native runtime does not implement, which is the gap
recorded in v0.1.174 and still its own slice. parity 79/79, ctest 13/13, dune
runtest 2308/0._

---

## v0.1.174 — 2026-08-11

_`examples/claims`: the shared-schema dogfood, stage 0 — build it the way you
would build it today, and count what is written by hand._

_An expense claim: title, date, purpose, a list of lines each with a category
that may carry its own text, an optional note and approver, a status. Enough
type variety that a naive answer to "generate the boilerplate" would not
survive it. `schema.mere` declares the record and the rules, and both replicas
import it._

_Half the boundary already costs nothing, which is worth stating before the
complaint. `to_json` / `of_json` are synthesised per type, so neither side
writes down a field name for the network — `examples/profile` has a hand-written
`serialize` and `parse_pairs`, and this one has neither. The validation
functions are the same functions on both sides, so a rule and its message exist
once. `problem` is a declared type, so the server's refusals arrive as records
rather than as text to parse, and a server-only rule (over ¥100,000 needs an
approver, and the approver must exist) lands in the same error slot a local
complaint would._

_The measured half: adding a `cost_center: str` field to `claim` takes four
edits in Mere and one in HTML, and the compiler catches exactly one of them —
the record initializer. The rule, the field table and the markup are all
silent. Stopping after the record and its initializer leaves a program where
both replicas compile, the server stores the field and the browser round-trips
it, and it never appears on screen; the rendered page mentions it zero times.
That is the number stage 2 exists to move._

_Two compiler findings fell out on the way. An extern whose result is `unit`
could not be used as a value at all: `unit` is Mere's int 0 and C's `void`, and
the closure adapter returned the call directly, so the emitted C returned void
from a function declared to return int. That is the shape of middleware —
contrib/http's `with_arena` wraps `http_arena_mark` — so no native build of a
server using it could compile. Fixed, with `test/ctests/extern_unit_as_value.mere`
holding it. And `of_json` on the C backend does not register container
instances that are reachable only through a record field type: a record with
both a nested record and a `list`/`option` field emits `unknown type name
'list_item'`. It is latent because a program that constructs one of those
values by hand anywhere registers it — which the claims app happens to do, and
a generated codec would not. That one is stage 1._

_The native HTTP runtime implements six externs, and `with_arena` /
`with_access_log` need two it does not have (`http_arena_mark`,
`http_current_status`). So a server that releases its per-request allocations
exists on the Wasm host and not the native one. Recorded, not fixed here.
parity 78/78, ctest 13/13, dune runtest 2308/0._

---

## v0.1.173 — 2026-08-10

_Two bugs behind one build failure: a regression from v0.1.172, and the latent
one it exposed._

_v0.1.172 left mere-ruby unable to compile — 19 `use of undeclared identifier
'mu_..._as_value'` — while parity, ctest and the OCaml suite all stayed green.
Both harnesses that compare stdout are blind to a program that never links, and
`scripts/ctest.sh`, which does invoke the C compiler, had not been run._

_The regression: in codegen_c the two arms that made a direct call to a
top-level or inner-lifted fn were folded into the new shadowing guard. That
guard is position-aware — a builtin used above a later same-named binding is
still the builtin — so any call it declined fell through to the closure path
instead of the direct one. Which of the three call shapes to use is a question
about what the name is, not about where in the file the caller sits, so the
fallthrough arm is back. (LLVM and Wasm were never affected: their equivalent
arms stayed in the match as a catch-all after the builtin arms.)_

_The latent bug that made it fatal: a polymorphic fn used at more than one type
is emitted once per instantiation under a mangled name, and `_as_value` closure
wrappers are only defined for those. The unmangled name stays registered in
`toplevel_fn_names` so source-level call sites still dispatch — so value
position asked for `<base>_as_value`, which is never defined. `let ident = fn
(x) -> x` used at two types and then passed as a value has never compiled on
the C backend; it now picks the instance from the reference's own type, the
same way the direct-call path does. Wasm refuses this case, which is honest —
it has no single function to hand out either — but said "unbound variable" for
a variable that is plainly bound, and now names the actual limitation._

_`test/parity/multi_inst_as_value.mere` covers it. A parity case rather than a
ctest because Wasm's refusal is a documented UNSUP there, and because parity
reports a backend whose output will not compile as MISCOMPILE — which is
exactly the signal that was missing. mere-ruby builds again and its corpus is
51/51 against ruby. parity 78/78, ctest 12/12, dune runtest 2308/0._

---

## v0.1.172 — 2026-08-10

_Shadowing a builtin, in general — the family the `join` fix in v0.1.169 was
one member of._

_Each backend dispatches on builtin names in about a hundred match arms, and
each arm decided on its own whether to ask if the program had bound that name
itself. Those questions had been added one incident at a time, after someone
was bitten: C had guarded 39 of 95, Wasm 14 of 139, LLVM 6 of 70. The rest were
silent. `let str_len = fn (s: str) -> 999` returned 999 on the interpreter and
5 on all three compiled backends — no error, no warning, a different answer.
Both a top-level and a local binding were affected._

_Each backend now asks once, before any builtin arm can match: if the head of
the application spine is a name the program bound, the call goes to the
ordinary call paths — inner-lifted fn, top-level fn, or closure value — and
never meets the builtin arms. Those three paths were already contiguous at the
end of each backend's App group, so they lifted out into one function
(`emit_user_app`, and a trio of local helpers in codegen_c) with nothing
duplicated. Safe by construction: the guard is false unless the program
actually bound the name, so a program that shadows nothing reaches exactly the
arms it reached before._

_The first version of the guard was wrong in a way worth recording. It asked
whether a name was bound **anywhere** in the program, but top-level bindings
are sequential — the typer rejects a forward reference — so a builtin used
above a later same-named binding is still the builtin. Under the first version
a helper written before `let show = ...` silently started calling the user's
show. Each backend now records the declaration position of every top-level fn
and the guard compares against the body being emitted, with `<=` so a
recursive fn still counts as binding its own name. Wasm needed the position
question asked ahead of its name-only tables (`fn_closure_table_idx`,
`top_globals_wasm` also hold top-level fn names), and LLVM needed the cursor
reset for main's body, which it emits without a host-scope switch._

_`test/parity/shadow_builtin.mere` covers the shapes the guard has to
recognise separately: bound at top level, locally, or as a capturing inner fn
that gets lifted; called with one argument or three (the name three levels
down a spine); used as a value rather than called; and the ordering rule.
parity 77/77, dune runtest 2308/0._

_Swept up while here: `file_size` / `file_pread` / `file_pwrite` left the LLVM
"no lowering yet" list they had been on since v0.1.163, the stale claim in
`test/parity/file_pio.mere` that LLVM refuses positioned I/O, and the example
count in `mere --help` (118 → 282)._

---

## v0.1.171 — 2026-08-10

_contrib/state: the one-slot-vec trick, named — and the thing naming it does
not fix._

_Mere has no mutable cell, and every browser client built one the same way: a
vec allocated once, pushed once, then read and written at index 0. It works —
the bump arena is page-lifetime, so the slot survives across event firings — and
by v0.1.170 there were ten of them across four apps, each with a comment
explaining the trick. `contrib/state/cell` names it: `cell_new` / `cell_get` /
`cell_set`, three lines over the same vec._

_That is the smaller half, because the noise was never the real problem.
`examples/profile` shipped with three of those cells and seven hand-written
calls to a recompute function, one after each mutation site; the seventh was
added during debugging, and the eighth would have been a screen quietly
disagreeing with the state behind it. `contrib/state/store` holds one value and
a list of watchers, and `store_update` writes and then tells them. The seven
calls became zero, and the app's three cells became one store._

_Making the screen derived forced the app to be honest about something the
first draft had fudged. Focusing a field takes its complaint off the screen but
does not make the value right — Save has to stay withheld until the field is
left and re-judged. The ad-hoc version got that by writing to the DOM behind
the state's back, which worked only because nothing else ever repainted. The
model now carries "what is wrong" and "what we are currently saying out loud"
as two separate facts, which is what they always were._

_`examples/tasks` keeps cells and no store, deliberately: its screen is not
derived from its state but reconciled against it — rows that stopped matching
are removed one at a time so the row being typed into is never rebuilt — and a
watcher that redrew on every write would destroy the one thing that app exists
to protect. Two of its four cells are a timer handle and a retry delay that
nothing renders at all._

_chat, tally and tasks moved to `cell`; profile moved to `store`. All four
still pass their harnesses (chat and tally and tasks headless, profile 15/15 in
Chrome). `test/parity/store_watch.mere` locks watcher order, the immediate
first run, read-modify-write, and two stores at different types across all four
backends. parity 77/77, dune runtest 2308/0._

---

## v0.1.170 — 2026-08-10

_A form, as opposed to a list — and the six bindings that separate the two._

_The three browser clients before this one were lists. A list is edited one item
at a time, every keystroke is worth acting on, and the only question the UI ever
asks is "what is on screen". `examples/profile` is a settings form, which is a
different animal: it is a set of fields with a shape. It is valid or it is not.
It differs from what was loaded or it does not. Answering either question means
holding two versions of the same record at once — what the server confirmed and
what the user has done since — and comparing them. The change count, whether
Save is offered, what Revert restores: all three are derived from that pair,
none of them is a flag anyone sets._

_Six bindings fall out, and each is here because the form cannot be written
without it. `dom_on_blur` and `dom_on_focus` are what make validation feel like
a form rather than a nag — judge the field when the user leaves it, take the
complaint back down when they return to fix it; checking on every keystroke
tells someone their email is invalid while they are still typing the part
before the `@`. `dom_on_change` is the only event a `<select>` produces, so
without it the theme picker is inert. `dom_checked` / `dom_set_checked` exist
because a checkbox has no useful `value` — its meaning is `el.checked`, a
property that is not the attribute of the same name. And `dom_remove_attr`
closes a hole `dom_set_attr` left in v0.1.152: a form could disable its save
button while the input was invalid and then never enable it again._

_The fields are described once — id, label, a getter, a setter, a check — and
everything else loops over that list: painting, comparing, validating,
reverting. Record fields cannot be named at runtime, so without the get/set
pair each of those loops would have been written out once per field._

_The server rejects things on purpose. The client checks what it can see; the
server also enforces a rule the client cannot know (a reserved display name)
and answers 422 with per-field messages, which land in the same error state a
local complaint does. `run_dom_headless.mjs` gained `--pick` and `--check` for
the two controls that are not text, `removeAttribute` and `checked` in its DOM
stub, and `value` / `checked` in its dump — a filled-in form used to render
identically to an empty one. `examples/profile/browser_check.mjs` covers what
the stub cannot: it can fire a blur, but only a browser can cause one. 15/15 in
Chrome, parity 76/76, dune runtest 2308/0._

_Correction: the version bump in v0.1.169 left `test/test_basic.ml`'s version
assertion pinned at 0.1.151, so that slice's suite was red as committed. Fixed
here._

---

## v0.1.169 — 2026-08-10

_`args ()` on LLVM — the last reason a Mere CLI ran on three backends out of
four — and the shadowing hole finding it exposed._

_The B+-tree in `mbtree` has run on all four backends since v0.1.163, when
positioned file I/O landed on LLVM. Its command line had not: `args` was still
interp + C, so `mere -ll` refused the program that wrapped the store. LLVM now
stores `main`'s argc/argv into globals and folds them into a `str list`,
dropping the program name, which is what interp and C hand back. `main` keeps
its no-argument signature unless the program actually asks for argv. The
strings are argv's own rather than copies into the current region: a str is a
plain NUL-terminated pointer on this backend and argv outlives the program, so
there is nothing to allocate and nothing that can outlive what it points at._

_Writing the parity case for it turned up something worse. The test defined a
`join` helper — the obvious name for joining strings — and LLVM lowered the
call to `pthread_join(i64)` and handed it a `str list`. `join` is also the
thread builtin, and LLVM guarded `str_eq` / `is_digit` / `is_alpha` /
`is_space` against a user's same-named binding but not `join`, which C has
guarded since Phase 30.0 with a comment predicting exactly this. The guards had
been added one incident at a time; they now go through one `user_shadows_llvm`
that asks about locals, lifted inner fns and top-level fns alike, the way C's
`user_shadows` does. `test/parity/shadow_builtin.mere` locks it down, and
docs/reserved-names.md gained the section distinguishing this axis — a name
Mere owns — from the C-symbol collisions the rest of that document is about._

_`mbtree data.db set 42 100` / `get` / `selftest` now produce identical output
on interp, C, LLVM and Wasm. parity 76/76, dune runtest 2308/0. `mere -v` also
reports the truth again: `lib/version.ml` had been left at 0.1.151 while the
changelog ran to 0.1.168._

---

## v0.1.168 — 2026-08-10

_A list you can filter and edit, and the three bindings it forced._

_Every browser client so far only appended, and a list that only grows can be
redrawn wholesale: `dom_set_text el ""` drops every child and the rest is
rebuilt from state. `examples/tasks` cannot. Each row holds an `<input>` you
type into, so rebuilding the list while you are editing takes the field out from
under the caret — which makes three things necessary rather than convenient.
`dom_remove` detaches one node and leaves its siblings, and their focus and
half-typed text, alone. `dom_on_input` fires on every keystroke, so the filter
can narrow as you type instead of on submit. `dom_set_timeout` /
`dom_clear_timeout` do two jobs: a keystroke cancels the pending filter and
queues a new one, so a burst of typing costs one re-render rather than one per
character; and a save that fails comes back on a doubling delay instead of being
dropped._

_Filtering reconciles rather than redraws: rows that stopped matching are
removed one at a time, rows that started matching are built and appended, and a
row that stays is never touched. The browser check asserts exactly that — after
typing in the search box, the row being edited is the same DOM node with its
caret still at offset 3 — along with delete removing exactly one row, and a save
failing and landing on the retry. All nine pass in Chrome._

_`examples/tasks/server.mere` is deliberately thin: contrib/store/kvlog behind
one tab-separated mutation endpoint, plus `POST /api/flaky` to fail the next N
saves on purpose, because a retry path that is never taken is a path that is
never tested. `scripts/run_dom_headless.mjs` gained `--type <id>=<text>`, which
sets a field and fires `input` the way a keystroke does, and its DOM stub now
implements `remove()`. parity 74/74, dune runtest 2308/0._

---

## v0.1.167 — 2026-08-10

_An open region is closed to the heap before codegen, which unblocks the last
LLVM gap the dogfoods hit._

_`vec_new` and `file_pread` hand back a `Vec[R, T]` whose region no `region`
block ever constrained, and the typer is content to leave R open. That is
harmless on the C backend, which erases types, and fatal on LLVM, which does
not — and the failure arrived three removes from its cause. An open R makes the
Vec non-concrete; a helper taking one is therefore not resolvable and gets
dropped from the backend's function list; the inner fn that uses it treats it as
a capture instead of a known top-level name; and the emitted call site refers to
an SSA value that does not exist. What clang reported was a type mismatch on a
register several functions away._

_A pass before lifting closes any open region variable to the default heap
region. That is completing the inference rather than working around it, which is
what keeps every downstream name stable — an earlier attempt tagged open regions
leniently instead, and made a struct's name depend on how far unification had
progressed, so the same type was registered under one name and referred to under
another._

_The B+-tree from the mbtree dogfood now compiles and runs on LLVM, and a tree
it writes there reads back correctly under the C backend.
`test/parity/lifted_vec_capture.mere` locks the shape. mbtree's CLI still needs
`args()`, which has no LLVM lowering. parity 74/74, dune runtest 2308/0._

---

## v0.1.166 — 2026-08-10

_Two corrections to the capture typing added in v0.1.165, and a precise account
of what still blocks mbtree on LLVM._

_`ty_is_concrete` is the wrong question to ask about a capture. A
`Vec[R, int]` whose region is still a variable is not concrete, yet
`llvm_ty_of` lowers every Vec to `ptr` and never looks at the region — so
rejecting it left the capture untyped. The lookup now asks whether the backend
can represent the type at all._

_v0.1.165 also fell back to searching every top-level fn body for a concrete
type of the captured NAME. Names are not unique across functions, so a capture
of `b : Vec[R, int]` picked up an unrelated `b : int` from elsewhere in the
program and was declared `i64`. Removed — a wrong type is worse than no type,
and the loud error is what should happen._

_What still blocks mbtree, stated exactly: `get_i8`, a top-level curried helper,
is not among the backend's `fn_decl`s, so the free-variable scan treats it as a
capture of the inner fn that uses it. Its type carries an unresolved region, and
the emitted call site refers to `%get_i8` — an SSA value that does not exist,
because the value is a top-level function. Two things would have to change: the
name would have to be known as a top-level binding so it is never captured, or a
captured top-level function would have to be materialised at the call site._

_A fix was attempted and backed out: tagging the region position of
`Vec` / `Map` / `StrBuf` leniently makes a struct's name depend on how far
unification has progressed, so the same type got registered under one name and
referred to under another, and `test/parity/bytes_typed_fn_unused.mere`
regressed to `llvm:MISCOMPILE`. Any real fix has to keep the tag stable.
parity 73/73, dune runtest 2308/0._

---

## v0.1.165 — 2026-08-10

_A capture the LLVM backend cannot type is refused instead of guessed._

_When an inner fn is lifted, each captured variable becomes a parameter, and the
capture's type came from the first `Var` occurrence inside the fn body whose
recorded type was fully concrete. When none was, the search fell through to its
initial value — `TyUnit`, which lowers to `i64`. So a capture the backend could
not type was silently declared `i64` while the call site passed a pointer, and
the failure surfaced as a clang type error about an SSA register, several steps
from the cause. That is what stopped the mbtree dogfood from building here._

_The lookup now prefers a concrete type, falls back to any recorded one, and
takes the binding site's type when a later use has been generalized; failing all
of that it raises a Mere codegen error naming the variable. mbtree's real
blocker is now stated plainly: `unsupported LLVM codegen type element: 'a` —
capturing a **polymorphic** value, which this backend cannot represent and the
lifting code already says so in a comment. The monomorphisation there covers a
local `let rec` applied at one type; a polymorphic top-level helper captured by
an inner fn is still open._

_parity 73/73, dune runtest 2308/0._

---

## v0.1.164 — 2026-08-10

_A partially applied extern is a value, not a call._

_The Wasm extern path collapses a curried `App` chain into one `call $name`,
taking the argument count from the call site rather than the declaration. That
is right when the application is saturated and emits a call with the wrong
arity when it is not, so `worker_call req` on a two-argument extern produced WAT
that wat2wasm rejected outright. Found while writing contrib/async, where the
whole premise is that an extern with its request applied is already a Task —
the tally client had to wrap every one in `fn (cb) -> … cb`._

_Under-application now eta-wraps: the missing arguments become a lambda and the
expression routes through the ordinary anonymous-closure path, so the partial
application is a closure like any other value. The wrapper is gone from
examples/tally/app.mere. Two regression tests pin both halves — a partial
application reaches its callee through `call_indirect`, a saturated one still
emits a direct `call`. parity 73/73, dune runtest 2308/0._

---

## v0.1.163 — 2026-08-10

_Positioned file I/O on LLVM, closing the last backend gap in that group._

_`file_openrw` / `file_size` / `file_pread` / `file_pwrite` / `file_fsync` /
`file_close` were interp + C + Wasm; parity reported `llvm:UNSUP` for
`test/parity/file_pio.mere`. The LLVM runtime now implements them over libc
with the same contract as everywhere else — a handle, bytes crossing as a
`Vec[int]`, a short read past EOF rather than a padded one — and that case is
`llvm:MATCH`. All four backends agree on writing past the end, overwriting a
window in the middle, and reading a window back after a reopen._

_A `File` travels as an i64 here rather than a raw `ptr`: lifted inner
functions type every parameter uniformly, so a pointer could not be passed
through one. The runtime converts at its own boundary._

_Not fixed, and worth naming because it is what stops the mbtree dogfood from
building on LLVM: a lifted inner function declares all its parameters `i64`,
so passing a **closure** to one fails to typecheck in the emitted IR. `args()`
also has no LLVM lowering. Neither is about files — mbtree hits both — but they
are the two things between this backend and running that dogfood. parity 73/73,
dune runtest 2306/0._

---

## v0.1.162 — 2026-08-10

_`mere install` fetches before checking out._

_A dependency's repo is cloned once and cached, keyed by repo-and-rev, but an
existing cache was never refreshed. So the first install after a new commit was
pushed failed with `fatal: reference is not a tree: <sha>`, and the only remedy
was deleting `~/.mere/cache` by hand — a git error with no mention of a cache,
a long way from the cause. It now fetches before checkout._

_Found while repointing the mere-blog dogfood at a current revision, which also
repaired its packaged path: its host was pinned to a release whose JS glue
predates the current value representation, so a build made with a current
compiler linked and then failed on its first request. With everything pinned to
one commit, `mere serve` runs that app on the vendored host end to end._

---

## v0.1.161 — 2026-08-10

_Sequencing for callback-shaped work, and what it does not fix._

_Everything that crosses a thread or a network hands its result to a closure.
One such call costs an indentation level, which is nothing. The cost shows up
when steps depend on each other: an ordinary fold over a list where each element
is a round trip cannot be written as a fold, and becomes a recursion carrying
its own continuation. The tally client had exactly that recursion written out by
hand, and so would every app that sequenced two requests._

_`contrib/async/async.mere` carries it once. A Task is `(str -> unit) -> unit`;
`async_each` is the fold, `async_map` collects results in list order rather than
completion order, `async_then` chains, `async_all` fans out and joins. It is
ordinary Mere — no language support, just the callback shape given names — and
`test/parity/async_combinators.mere` pins the ordering across all four
backends. examples/tally/app.mere now uses it and the hand-rolled recursion is
gone._

_What it does not fix is the nesting: `async_then` still puts each step inside
the previous one's closure, so the four-step sync in tally is four levels deep.
Removing that needs syntax, not a library — some form of do-notation or await —
and shipping the combinators first is how to find out how much of the pain was
the fold and how much is the nesting. On the evidence of one app: the fold was
the part worth removing, and the nesting is legible enough to live with for now._

_Found while writing it: an extern cannot be partially applied on the Wasm
backend. `worker_call req` emits a direct one-argument call rather than a
closure, so a Task built from an extern still needs an explicit
`fn (cb) -> extern req cb`. Worth eta-wrapping the way nullary builtins already
are._

---

## v0.1.160 — 2026-08-10

_A request's allocations can be released when the request ends._

_The default region is a bump arena with no free, so a long-lived server keeps
every request's working memory forever — the parsed body, the strings a handler
concatenated on the way to a response, and every string the host wrote in. A
handler that builds a 200-piece string cost 162,840 bytes per request, none of
it reclaimed. The dogfoods noted this as a constraint twice without measuring
it; the number above is a 300-request run against a Node host, reading the
module's own `__lang_bump`._

_`contrib/http/arena.mere` marks the arena on the way into a request, and the
glue rewinds it once the response has been copied out of linear memory. Same
handler, same run: **24 bytes per request**, and 200 consecutive responses are
byte-identical, so nothing is reclaimed early. A plain `region` block around the
handler gets most of the way there on its own (162,840 → 722, the copied-out
response), which is worth knowing when no host cooperation is available._

_It is opt-in, and the reason is the rule it depends on: nothing a handler
allocates may outlive its response. That holds for ordinary request/response
work and fails for a handler that stashes a value in something longer-lived —
an in-memory session store, a cache, a subscriber list. mere-blog is exactly
that case and deliberately does not use it; `examples/tally/server.mere` keeps
all its state in a log file and does._

_parity 72/72, dune runtest 2306/0; the tally client still syncs against the
wrapped server._

---

## v0.1.159 — 2026-08-10

_`args()` returns the arguments on a plain Wasm host._

_The runners have supplied `arg_count` / `arg_get` for a long time; the builtin
was never wired to them and returned Nil unconditionally, so a CLI compiled to
Wasm silently saw no arguments while the same source on C saw them all — a
disagreement with no error anywhere. It now builds the list from the host, and a
host that reports 0 yields Nil, which is what the hardcoded empty list got right
for a browser. contrib/dom answers 0 so a page keeps the behaviour it had._

_Verified by running the same program on both backends with arguments: `foo bar`
gives `n=2 [foo] [bar]` on C and on Wasm. parity 72/72, dune runtest 2306/0._

---

## v0.1.158 — 2026-08-10

_One definition of the host boundary, instead of five._

_v0.1.157 added a number so a host and a module could refuse each other. This
removes the reason they drifted in the first place: `readCStr`, `writeStr`,
`bumpAlloc` and the closure caller existed in five separate copies, and a fix to
one never reached the others. `run_wasm.js` grew the string length header and
open-coded it at four call sites; contrib/dom learned the i64 closure convention
and contrib/http did not; a fixed 4KB scratch window outlived the move to the
shared heap in exactly one glue. Each was a wrong answer at runtime, never a
link error._

_`scripts/mere_host.js` now holds all of it — `makeMarshal` for the four value
operations plus `writeBytes` / `readBytes` / `copyToStr` for the byte buffers a
driver moves, and `makeClosureCaller` for dispatch — with the layout written
down once at the top. `run_wasm.js`, `run_http_server.js`, `pg_env.js` and
`contrib/http/http.glue.js` all use it: 251 lines deleted, 48 added._

_`contrib/dom/dom.glue.js` keeps its copy, because it is an ES module a browser
fetches and cannot require the shared one. That is now the only place the layout
appears twice, so `scripts/check_host_abi.js` checks it: the ABI constants must
agree, and the copy must still write the length header, return a pointer past
it, and pass closure arguments as BigInt. Each of those three was wrong in some
host at some point._

_parity 72/72, dune runtest 2306/0; the chat, tally and mere-blog apps all
rebuild and pass their checks. The ABI guard earned itself immediately — a
stale mbtree build from before v0.1.157 was refused by name instead of quietly
returning empty strings._

---

## v0.1.157 — 2026-08-10

_An ABI number, so a host and a module can refuse each other._

_Nearly every bug the three dogfoods turned up was one shape: a boundary written
when a Mere value was 4 bytes and a `str` was a plain C string, left behind when
both changed. A host and a compiled module agree on far more than the import
list — the value representation, the string layout, how a closure is called —
and none of it is checked, so an older host links cleanly and then returns empty
strings or crashes on the first request. That is how a request line arrived as
"", how a password hash hashed to nothing, and how a result set came back with
every column empty._

_Every module now exports `__mere_abi`, and every host checks it before touching
the instance: `scripts/mere_abi.js` for the Node runners and contrib/http,
inlined in contrib/dom since it loads in a browser. A module without the global
is refused as pre-ABI-1 with a note to recompile; a newer one tells the host to
update. The self-host emitter in `contrib/codegen/codegen_wasm.mere` emits the
same global, so both codegens stay in step and the bootstrap fixpoint still
holds._

_ABI 1 names what was implicit: i64 values with addresses in the low word,
`[i32 len][bytes][NUL]` strings whose value points at byte0, closure records of
`{ i32 env, i32 fn_idx }` called as `(i64, i64) -> i64`, 8-byte compound fields
and 16-byte `{ tag, payload }` variant cells._

_An audit of the remaining host boundaries found three more of the same shape,
all in `run_http_server.js` and all fixed by routing through the shared
`writeStr` rather than open-coding the layout a fourth time: `getenv`,
`sha256_hex` and `__lang_str_of_float`. Open-coding is precisely how these
drifted — `run_wasm.js` grew the length header at each of its own call sites and
none of the copies elsewhere followed. parity 72/72, dune runtest 2306/0._

---

## v0.1.156 — 2026-08-10

_`of_json` gets a working Wasm backend, and the last of the raw-C-string
handoffs go._

_**The Wasm JSON decoder was written for the 4-byte value model.** The parser
runtime carried i64 signatures over i32 bodies, and the generated `__ojnode_*`
decoders built records with 4-byte fields and variant cells of 8 bytes, so
typed request decoding had no Wasm backend at all. The runtime's JSON tree is
private to the parser and now says so — i32 throughout — while every decoder
produces a real Mere value: 8-byte record and tuple slots, 16-byte
`{ tag, payload }` cells, and `__mj_atoi` accumulating in i64 so a number past
2^53 survives. `test/parity/of_json_composite.mere` covers records, lists,
options (including None-on-error), nested lists of records, variants both
nullary and payload-carrying, and the wide integer._

_**`show` and `to_json` on C returned bare string literals** for bool, unit,
closures, the empty list, nullary constructors and every `null` — and a bare
literal is not a Mere str, which carries its length in the word before byte0.
`print (show true)` looked fine because print formats with %s and stops at the
NUL; `print ("x" ++ show true)` segfaulted, and `str_len (show true)` returned
whatever preceded the literal in rodata. Same for `str_repeat` at n≤0,
`str_join` of an empty list, and `__lang_fail_str`._

_**Two Wasm hosts still handed over raw bytes**: `mem_to_str` in
`scripts/pg_env.js`, which is where every column value a database driver reads
off the wire becomes a str — an entire result set came back empty — and
`read_file` in `scripts/run_http_server.js`. And `contrib/http/http.glue.js`
read the response body by scanning for a NUL, so a `.wasm` asset served out of
`read_file` truncated to nothing at its first byte._

_Together these close the gap the previous entry left open: mere-blog now
builds and runs on **both** backends against Postgres — signup, cookie
sessions, typed request decoding, authenticated post creation — and serves the
same Wasm admin client byte-identically from either. The admin UI's browser
checks pass against the native binary and the Wasm host alike. parity 72/72,
dune runtest 2306/0._

---

## v0.1.155 — 2026-08-10

_Four boundaries that a database-backed web app walks straight into, found by
building an admin UI for the mere-blog dogfood._

_**`to_json` on Wasm** had the same rot `show` did at v0.1.153: every case of
the emitter built 4-byte cells with i32 fields and kept the accumulator str in
an i32 local, so a module that serialized anything was rejected by wat2wasm.
`to_json_int` also read its i64 argument through i32 comparisons, so sign and
magnitude were wrong past the low word. mere-blog serializes a typed record on
every response, so the whole Wasm backend was unavailable to it.
`test/parity/to_json_composite.mere` covers it._

_**The native runtime handed Mere raw C strings.** A Mere `str` is
`[size_t len][bytes][NUL]` with the value at byte0, so `__lang_str_size` reads
the length from `s[-1]` — and the native HTTP server passed a `static char[]`
request line straight to the handler, which read back as "". Every route on a
native build 404'd. Same for `http_current_body` and `http_get_header`, and for
the crypto/encoding externs: `__to_hex` / `__to_b64` / `gen_request_id`
malloc'd their results, so `sha256_hex` returned "" and every password hash
with it. They now allocate through `__lang_str_alloc`._

_**A `unit` parameter broke extern closure adapters on C.** `extern fn f: unit
-> str` lowers to `str f(void)`, but the adapter that lets it be used as a
value passed its argument through, calling a 0-arity function with one._

_**The native HTTP response measured its body with `strlen`.** A Mere str
carries its length and may contain NULs, so a `.wasm` read through `read_file`
was truncated at its first zero byte — a native Mere server could not serve its
own compiled client. It now uses `__lang_str_size`._

_Together those let mere-blog build and run natively against Postgres with a
current compiler — signup, cookie sessions, authenticated post creation — and
serve a Wasm admin client whose form validates drafts with the same
`validate.mere` the server enforces, compiled to Wasm on one side and C on the
other. parity 71/71, dune runtest 2306/0._

_Known and not fixed: `of_json` on Wasm is still entirely 4-byte-model, runtime
and generated decoders both, so typed request decoding has no Wasm backend
until that is rebuilt. Native and interpreter are unaffected._

---

## v0.1.154 — 2026-08-10

_A local-first app in Mere, split across three replicas of one store.
`contrib/store/kvlog.mere` is an append-only key/value log over the
positioned file I/O from v0.1.153: a write appends a record and fsyncs, a
read replays. `examples/tally` runs it three ways — `store.mere` owns the
browser's copy off the UI thread, `server.mere` owns the authoritative
copy, and both `import` the same kvlog source, so the two replicas are
one store compiled twice rather than two stores that agree on a format.
A log written by the C backend reads back under Wasm and interp, and the
reverse. `file_size` joins the positioned group on Wasm, since an
append-only store needs the end of the file without reading it._

_The UI half (`app.mere`) reaches storage through a new `worker_call`
binding in contrib/dom: a request string in, a reply handed to a closure
later. In a browser that is postMessage to a Worker, which is where the
store has to live because an OPFS access handle — the only synchronous
positioned file I/O a browser offers — exists only off the main thread.
`scripts/run_dom_headless.mjs --worker <store.wasm>` runs the same split
under Node with replies deferred to a later turn, so the asynchrony is
faithful and the whole app is testable without a browser: add a counter,
reopen in a fresh process and see it persisted, press +1, sync against a
running server, and lose the server and watch it fall back to local.
`examples/tally/store.worker.js` carries the OPFS binding, and
`scripts/check_browser.mjs` drives it in Chrome: write through the store,
reload, restart the browser process, and confirm the counters come back
off disk. Playwright is not a dependency, so a missing install is a SKIP.
The check also confirms `createSyncAccessHandle` is absent on the main
thread, which is the constraint the whole split exists for. A log written
by the browser through OPFS parses identically under `kvlog.mere`
compiled to C and run natively, and compiled to Wasm and run under Node —
one source, three hosts, one byte format._

_What the split says about the language. Every endpoint is straight-line
code — `handle` in store.mere returns its reply as a value and never
mentions asynchrony — and every crossing is a callback. With one request
in flight that costs an indentation level, which is what the chat client
measured in v0.1.152. The cost shows up when steps depend on each other:
sync reads local state, fetches remote, writes the merge back key by key,
then publishes it, and the middle step is an ordinary fold over a list
where each element is a round trip. Written against callbacks it becomes
a recursion that carries its own continuation and calls it when the list
runs out. That rewrite — a fold that cannot be a fold — is the clearest
argument so far for giving Mere a way to name the result of a call._

_Also found: a `let rec` that closes over a Vec is rejected by both
compiled backends ("captured variable has no recorded type" on C,
"inner-lifted capture not in scope" on Wasm), so kvlog threads its byte
buffer through as an explicit parameter. And `dom_set_text el ""` turns
out to be the way to clear a container, since setting textContent drops
every child — no `dom_remove` binding needed yet._

---

## v0.1.153 — 2026-08-09

_Positioned file I/O on the Wasm backend, and the three broken builtins that
finding it uncovered. `file_openrw` / `file_pread` / `file_pwrite` /
`file_fsync` / `file_close` were interp + C only, on the reasoning that Wasm
has no filesystem. That is true of the browser main thread and false of a
Worker, which gets synchronous positioned read / write / flush from an OPFS
access handle — the same contract these builtins already describe. They now
lower to host imports, with bytes crossing in the `mere_bytes` layout the
`read_file_bytes` path already uses, so there is no per-byte host crossing and
the host never needs to know the Vec layout. `scripts/run_wasm.js` backs them
with positioned `fs` calls against a handle table._

_The result: mbtree — a persistent B+-tree written against those builtins —
compiles to Wasm unchanged and passes its durability selftest (20 keys, node
splits, a root split, fsync, close, reopen) on interp, C and Wasm alike. A tree
file written by the C backend reads back correctly under Wasm and interp, and
the reverse, so the on-disk format is one format across backends rather than
three that happen to agree._

_Getting there needed three fixes to builtins that were stale for the i64 value
model and that nothing exercised. `show` over any composite type emitted WAT
that wat2wasm rejected — the tuple, record, variant and list emitters all still
built 4-byte cells with i32 fields and kept the str accumulator in an i32 local
— so `print (show [1, 2, 3])` could not be assembled at all. `vec_to_list` on
Wasm had the same rot. On LLVM, `vec_to_list` stored the payload tuple into the
node by value, but the Phase 24 variant layout makes that field a pointer, so
16 bytes went into an 8-byte slot and the helper segfaulted for any input.
`test/parity/show_composite.mere` and `test/parity/file_pio.mere` cover both
gaps; the existing 68 parity inputs only ever showed scalars and never opened a
file handle. Full suite: parity 70/70, dune runtest 2306/0._

_Known, not fixed: `args()` on the plain Wasm backend is hardcoded to the empty
list even though `run_wasm.js` supplies `arg_count` / `arg_get`, so a CLI
program silently sees no arguments there while the C backend sees them. Correct
for a browser host, wrong under Node._

---

## v0.1.152 — 2026-08-09

_The chat client rewritten in Mere, and the four stale host boundaries it
exposed. `examples/chat/app.mere` replaces the 74 lines of hand-written
JavaScript that `examples/http_chat.mere` used to serve, so both halves of the
demo are now Mere and both share `contrib/http/escape.mere` for JSON escaping —
one implementation compiled to C on the server and Wasm in the browser.
`contrib/dom` gains 12 externs in the three groups a document-shaped app needs
and a game does not: element construction (`dom_create` / `dom_append` /
`dom_set_attr` / `dom_set_value` / `dom_scroll_to_end` / `dom_on_submit`),
request/response (`dom_fetch` blocking + `dom_fetch_async` callback, sharing
`dom_fetch_status` / `dom_fetch_header`), and server push (`dom_sse`). Both
request shapes ship deliberately: the app performs its bootstrap through each
so the cost of a callback continuation is visible in Mere source rather than
argued about._

_Four host-side boundaries had drifted from the compiler and only a real app
touched them. **`str` layout**: `mere_strbuf_to_str` in `lib/codegen_wasm.ml`
hand-rolled its bump allocation and skipped the `[i32 len]` header that
`__lang_strlen` reads from `ptr-4`, so every `strbuf_to_str` result read back as
`""` on Wasm alone — invisible under `print`, which exits through the host and
scans to NUL. The same header was missing from the `writeStr` helpers in
`contrib/http/http.glue.js`, `contrib/dom/dom.glue.js`, `scripts/run_wasm.js`
and `scripts/pg_env.js`; `run_wasm.js` had the correct sequence open-coded at
four call sites, which is why the fix never reached the shared helpers.
**Closure ABI**: `http.glue.js` still passed plain numbers to the
`(param i64 i64)` closure type v0.1.127 introduced, so every `contrib/http`
demo threw on its first request when rebuilt. **Scratch memory**:
`dom.glue.js` still wrote host strings into a fixed 4KB window at 56K that
wrapped around, which a multi-KB bootstrap response overruns. **Missing
import**: the runners never supplied `time`, which the prelude imports
unconditionally. `test/parity/strbuf.mere` closes the coverage gap that let the
first of these live — StrBuf had no parity case among the other 68._

_`contrib/http/static.mere` now serves assets through a new `http_send_file`
host extern instead of `read_file`. Mere strings are NUL-terminated, so the old
path truncated any binary file at its first zero byte, and a `.wasm` module
begins with one: the server could not serve its own compiled client. Bytes now
go from disk to socket without entering Mere, which also distinguishes an empty
file from ENOENT. `scripts/run_dom_headless.mjs` runs a `mere -w` module
against `contrib/dom` under Node with a small DOM, `fetch`, synchronous XHR and
`EventSource`, so browser-targeted Mere is testable without a browser._

---

## v0.1.151 — 2026-08-08

_RV32I fantasy-console I/O + a browser build. Two new externs the `mere -rv`
backend lowers to memory-mapped I/O and a syscall, turning a `mere -rv` program
into a playable cartridge: `key n` reads the held state of button `n` from an
input register at `0x7F9000 + n` (a `lbu`), and `present ()` ends a frame and
yields to the host via `ecall a7=100`, resuming on the next instruction next
frame — so a program's main loop is a coroutine whose state lives on the RISC-V
call stack. Paired with the existing `fb_set` (framebuffer store), these three
are the whole hardware contract. `contrib/site/playground/rvconsole.mere` is
the memu RV32IM emulator compiled to WebAssembly and wired to the DOM (ROM via
`dom_rom_byte`, input via `dom_key_held`, framebuffer blitted to a `<canvas>`),
and `game.mere` is an arrow-key-playable cartridge; both ship to the playground.
`lib/codegen_riscv.ml`, `contrib/site/build_full.sh`, `contrib/site/build.mere`._

---

## v0.1.150 — 2026-08-08

_Full structural `==` / `!=` on the RV32I backend. A comparison at a compound
type (tuple, record, or payload-carrying variant) now generates a per-type
`__eq_<tag>(a,b)` helper that recurses over the structure — mirroring
codegen_c's `eq_<tag>`. Helpers are deduped by a type tag and emitted from a
worklist, so recursive types (e.g. a cons list) terminate; type parameters are
substituted with the concrete arguments at the use site, so `list int` and
`list str` get distinct monomorphic helpers. Verified byte-identical to the
interpreter across tuples, records, single- and tuple-payload constructors,
`Circle 5` vs `Dot`, a recursive `ilist`, `option`, and a tuple with a string
field. Only `==` on functions is rejected. `lib/codegen_riscv.ml`._

---

## v0.1.149 — 2026-08-08

_A framebuffer primitive for the RV32I backend: `fb_set x y v` lowers to a
byte store into a 64×32 framebuffer at 0x7F8000 (above the stack). Declared in
a program as `extern fn fb_set: int -> int -> int -> unit;`, it lets a Mere
program draw pixels; an emulator that renders that region turns it into a tiny
"fantasy console" — a Mere program, compiled by `mere -rv`, drawing graphics
on the Mere RISC-V CPU (see the memu project's riscv-console demo).
`lib/codegen_riscv.ml`._

---

## v0.1.148 — 2026-08-08

_Correct `==` / `!=` on enums (RV32I). A comparison at a non-primitive type was
comparing heap pointers; now an all-nullary variant type (an enum) compares its
tag word, which is exact. Compound values (tuples, functions, payload-carrying
constructors) would need a recursive structural equality — they now raise a
clear Codegen_error pointing at pattern matching instead of silently comparing
pointers. Ints/bools/type-variables are unaffected. `lib/codegen_riscv.ml`._

---

## v0.1.147 — 2026-08-08 — the Mere compiler runs on the Mere CPU

_The self-hosting tower closes: the Mere-written compiler (lexer + parser +
typer + Wasm codegen), lowered by `mere -rv` to a ~380KB RV32IM binary, runs
on the Mere-written RV32I emulator and emits WAT byte-identical to the
interpreter. Self-language → self-backend → self-CPU._

_The last bug was a memory-map overlap: the globals+heap region sat at 0x10000
(64KB), but the self-hosted compiler's code is ~88KB and extended past it, so
a global write corrupted the code and the program jumped into garbage. Small
programs (<64KB of code) never hit it. Fix: move globals+heap to 0x200000
(2MB), well above any code — layout is now code [0,2MB) | globals+heap ↑ |
stack ↓ from 0x7E0000 | print scratch 0x7F0000 (needs an ≥8MB emulator). Global
slot addressing now materialises the full address, so the global count is
unbounded. Verified: the self-hosted compiler produces byte-identical WAT on
RV32I for arithmetic, let/if, and a recursive factorial (133 lines of WAT);
all existing tests still pass. `lib/codegen_riscv.ml`._

---

## v0.1.146 — 2026-08-08

_Long-range conditional branches on the RV32I backend. A bare B-type branch
reaches only ±4KB and silently truncated its offset in large functions (the
self-hosted compiler has functions well past that). Every conditional branch
is now emitted as an inverted branch skipping a J-type jump (±1MB reach), so
branch targets are correct at any distance. All existing tests stay
byte-identical to the interpreter. `lib/codegen_riscv.ml`._

---

## v0.1.145 — 2026-08-08

_An injected Mere-source runtime prelude for the RV32I backend
(`lib/rv_prelude.ml`) — the string / char-class / Map tail the self-hosted
compiler needs, written on top of the primitives codegen_riscv emits instead
of hand-assembled. `mere -rv` prepends it to the user source, so it goes
through the normal typer + desugar; the definitions shadow the builtins of
the same name (compile_app resolves user bindings first) and reachability
emits only the ones a program uses. Provides `is_digit`/`is_alpha`/`is_space`,
`not`, and `str_starts_with` / `str_ends_with` / `str_index_of` /
`str_contains` / `str_repeat` / `str_rev` / `to_lower` / `to_upper` /
`str_trim` / `str_join` / `str_split` / `str_replace` / `str_unescape` /
`int_of_str`. **Map** is an assoc-list in a one-cell Vec with `str_eq` keys
(mirroring the self-hosted Wasm backend): since the typer forces the `Map`
type on the `map_new` name, codegen_riscv intercepts the `map_*` builtins and
dispatches to `rvmap_*` helpers. Also relocated the print scratch buffer out
of the heap region (to 0x7F0000, stack to 0x7E0000) so large programs don't
clobber it. Verified byte-identical to the interpreter across the whole
string/Map surface; existing tests still pass. With this, the Mere-written
compiler compiles to a ~94k-instruction RV32I binary and runs on the emulator
(reaching its own typer) — the last correctness gaps on real input are being
chased. `lib/codegen_riscv.ml`, `lib/rv_prelude.ml`._

---

## v0.1.144 — 2026-08-08

_Vec — a mutable, growable array — on the RV32I backend (M3). A Vec is a
`[len][cap][dataptr]` cell over a cap-word buffer; `vec_push` doubles the
buffer when full (allocating a new one and copying, since the bump heap can't
realloc). `vec_new` / `vec_push` are runtime helpers; `vec_get` / `vec_set` /
`vec_len` are inlined. Verified byte-identical to the interpreter across
push/get/set/len, growth well past the initial capacity, and an iterating
sum. (`ref` turned out to be unused in the self-hosted compiler — Mere's
mutability flows through Vec/Map, so no separate reference cell is needed.)
Remaining for self-host: the `Map` collection and a tail of string builtins
(`str_replace` / `str_join` / `str_split` / …). `lib/codegen_riscv.ml`._

---

## v0.1.143 — 2026-08-08

_A big step toward self-hosting on RV32I — driven by feeding the Mere-written
compiler (lexer + parser + typer + codegen) through `mere -rv` and closing
each gap it hit:_

- _**Top-level value bindings (globals).** Non-function top-level `let`s now
  live in a fixed memory region (below the heap), initialised in order at the
  start of `__main`; any top-level function can read them. The peeler no
  longer stops at the first non-function binding, so functions defined after a
  value binding are still lifted._
- _**Recursive local closures** (`let rec f = fn ... in ...`): the closure is
  allocated first and `f` bound to it before the captures are filled, so the
  body's self-reference resolves._
- _**Fully-recursive pattern binding** (arbitrarily nested tuples / records /
  constructors; `as`-patterns; string patterns) via a container-pointer parked
  on the stack. **Record update** `{ r | f = e }`. `region { }` is a no-op
  (the bump heap doesn't reclaim)._
- _**String / char builtins:** `str_of_int`, `ord`, `chr`, `char_at`,
  `substring`, `print_no_nl`, `fail`, and int-only `show`; plus **StrBuf**
  (`strbuf_new` / `strbuf_push` / `strbuf_to_str` / `strbuf_len`)._
- _**> 8-argument calls:** args beyond a0–a7 are passed on the stack with
  caller cleanup._
- _**Fix:** a user binding (local / global / top-level) now shadows a
  same-named builtin, matching the interpreter._

_All existing RV32I tests remain byte-identical to the interpreter. The
self-hosted compiler now gets much deeper before hitting the remaining gaps
(more string builtins like `str_replace`, and the `Vec`/`Map` collections).
`lib/codegen_riscv.ml`._

---

## v0.1.142 — 2026-08-08

_Records on the RV32I backend (M3, second slice). A record is a heap block
whose fields are laid out in declaration order (from the `Top_record`
decl); a `Record_lit` reorders its fields to that order, evaluates, and
fills the block, a `p.field` reads the field's slot (the field's index is
resolved from `p`'s type via the typer's `.ty`), and a record pattern
`T { f = a, .. }` binds each field by its offset — in both `let` and
`match`. Verified byte-identical to the interpreter across construction,
field access, out-of-order literals, record pattern destructuring in
`let`, a string field, nested records (`s.a.x`), and field patterns with
guards in `match`. Next: attempt the Mere-written `selfhost-compile`.
`lib/codegen_riscv.ml`._

---

## v0.1.141 — 2026-08-08

_String builtins + content comparison on the RV32I backend (M3, first
slice toward self-hosting). `==` / `!=` / `<` / `<=` / `>` / `>=` on
`str`-typed operands now compare content, not pointers (dispatched on the
typer's `.ty`), via new `__str_eq` / `__str_cmp` runtime helpers (the
latter normalised to -1/0/1, matching the interpreter). New builtins:
`str_of_int` (itoa into a heap string), `str_eq`, `str_compare`, `ord`,
`chr`, `char_at`, `substring` (end-exclusive, matching the interpreter's
`String.sub s start (end-start)`), and `print_no_nl`. Verified
byte-identical to the interpreter across equality/ordering, signed
`str_of_int`, char access, and substring. Next M3 steps: records, then
attempting the Mere-written `selfhost-compile`. `lib/codegen_riscv.ml`._

---

## v0.1.140 — 2026-08-08

_Closures on the RV32I backend (M2, final slice) — the last piece before
self-hosting. A closure is a heap block `[code_ptr][captured...]`; `fn x ->
body` captures the locals its body uses, lifts the body to a top-level
lambda (`code(env in a0, arg in a1)` — captures loaded from the env at
entry, param from a1), and evaluates to the block. Application splits two
ways: a saturated direct call to a known top-level function keeps the fast
register-allocated `jal` path, while everything else (lambdas, higher-order
params, curried/partial application through values) evaluates the head to a
closure and applies arguments one at a time via an indirect `jalr`. That
unlocks first-class and higher-order functions: verified byte-identical to
the interpreter for apply/twice/compose, free-variable capture, and — the
milestone — the prelude's own `list_map` / `list_fold` / `list_filter` /
`range` / `list_product` driven by lambda arguments over a `Cons`/`Nil`
list, all running on the Mere-written CPU. (Partial application of a bare
top-level function still wants an explicit lambda; a follow-up.)
`lib/codegen_riscv.ml`._

---

## v0.1.139 — 2026-08-08

_Strings on the RV32I backend (M2, third slice). A string is a pointer to
`[len:4][bytes][pad to 4]`. Literals become rodata blocks emitted after the
code, loaded by a new `LoadAddr` item (lui+addi of the label's absolute
address — the binary loads at 0, so absolute = offset); a new `Bytes` item
carries the raw data. `print` writes the bytes then a newline
(print_endline semantics, matching the interpreter), `++` calls a new
`__str_concat` runtime helper that bump-allocates and byte-copies both
operands, and `str_len` reads the length header. Verified byte-identical to
the interpreter for literals, concat chains, `str_len`, and strings flowing
through functions, an ADT payload, and tuple destructuring. `mere -rvs` now
also lists the rodata. Next: closures (the last M2 piece before selfhost).
`lib/codegen_riscv.ml`._

---

## v0.1.138 — 2026-08-08

_ADTs and pattern matching on the RV32I backend (M2, second slice). A
constructor is a heap block `[tag][payload]` — the tag is the variant's
index within its type (from Top_type decls), the payload is one word (an
int, or a pointer; a tuple pointer when the constructor has several
fields). `match` stashes the scrutinee in a binding slot, then for each arm
tests the pattern (constructor tag compare, int/bool literal, or an
irrefutable tuple/var bind) — branching to the next arm on mismatch — and
binds its variables before running the body; guards are supported. Covers
the top level plus one level of sub-structure, enough for Option/Result and
typical enums (deeper nesting raises a clear Codegen_error). Verified
byte-identical to the interpreter across a nullary enum, single- and
tuple-payload constructors, a recursive `ilist` (sum/len/max over a
hand-rolled cons list), and the built-in `option`. Next: strings, then
closures. `lib/codegen_riscv.ml`._

---

## v0.1.137 — 2026-08-08

_The RV32I backend grows a heap (M2, first slice) — tuples. `_start` now
sets `gp` as a bump-heap top pointer (heap at 0x10000, below the print
buffer and stack); a tuple literal evaluates its elements onto the memory
stack, bump-allocates an n-word block, and fills it (no call between the
bump and the stores, so the block pointer stays put), leaving the pointer
as its value. A tuple-pattern `let (a, b, ...) = e` loads each field into
its binding. This is the first non-integer value representation — values
are now "a word that is either an int or a heap pointer". Verified
byte-identical to the interpreter across tuple construction, 3-field
tuples, tuple-returning functions, elements that are themselves calls,
tuple-in/tuple-out (swap), and nested-tuple dot products. Next slices:
ADTs + Match, strings, closures. `lib/codegen_riscv.ml`._

---

## v0.1.136 — 2026-08-08

_A disassembler for the RV32I backend — the debugging surface the direct
byte-emitter skipped. `lib/riscv_disasm.ml` decodes one RV32IM word to a
readable mnemonic (mirroring the emulator's imm_* decoders, inverse of the
enc_* encoders), recognising the mv / li / ret / j / nop / beqz pseudo-ops.
Two new modes use it: `mere -rvs file.mere` prints an assembly listing of
the compiler's own output (address, hex, mnemonic, with real label names on
jumps/branches), and `mere -rvd file.bin` disassembles a flat binary. This
makes the register-allocated code inspectable — e.g. factorial shows the
param pinned in s1, `n <= 1` folded to `slti a0, a0, 2`, and `n * fact(n-1)`
as `mul a0, s1, a0` — and sets up debugging for the heap/closure work
ahead._

---

## v0.1.135 — 2026-08-08

_Register allocation for the RV32I backend (M1). The M0 stack machine kept
every named binding in a memory frame slot and every intermediate on the
memory stack; M1 puts a function's params and lets in the callee-saved
registers s1..s11 (spilling only the 12th-plus binding to memory), folds
the hot `n - 1` / `n < 2` of recursion into a single `addi` / `slti`, and
reads binop/comparison operands straight out of their registers when
possible — a value in a callee-saved register survives the other operand's
evaluation, nested calls included, so no spill is needed. Static
instruction count drops 16–32% (~23% average) across the sample programs;
still byte-identical to the interpreter across factorial, Fibonacci(25),
Ackermann, deep recursion (sumto 1000), gcd, and a 14-local function that
exercises the memory-overflow path. `lib/codegen_riscv.ml`._

---

## v0.1.134 — 2026-08-08

_A fifth backend — Mere lowers to native RV32IM machine code. Where `-c`
/ `-ll` / `-w` delegate to a C compiler / LLVM / a Wasm runtime,
`mere -rv file.mere` emits a **flat little-endian binary** directly (no
external assembler or linker) that runs on the Mere-written RV32I
emulator: the self-made language now runs on the self-made CPU. This is
the M0 vertical slice — 32-bit integers, arithmetic, comparisons,
short-circuit `&&`/`||`, `if`, `let`, top-level (mutually) recursive
functions, saturated calls, and `print_int` — lowered by a simple stack
machine (a0 accumulator, fp-relative frame slots, no register allocation
yet) with a two-pass label assembler and a self-contained `_start` /
`print_int` (itoa + `ecall write`) runtime. Only the top-level functions
reachable from `main` are emitted, so the prelude is skipped entirely.
Anything outside the slice (closures, strings, ADTs, heap) raises a clear
`Codegen_error`. Verified byte-identical to the interpreter across
recursion (factorial, Fibonacci, Ackermann), mutual recursion, gcd,
short-circuit logic, and signed div/mod. `lib/codegen_riscv.ml`._

---

## v0.1.129 — 2026-08-07

_Byte-safe strings on the Wasm backend — the arc that made C strings
byte-safe (v0.1.127) now extends to Wasm. A `str` in linear memory is
`[i32 len][bytes][NUL]`: the length header lives immediately before the
pointer, so embedded NULs survive (`("a" ++ chr 0 ++ "b")` has length 3)
while NUL-free strings stay host/C-interop compatible via the preserved
terminator. `__lang_strlen` reads the header; a new `__lang_str_alloc`
centralises header-writing allocation; every string producer (concat,
substring, trim, rev, repeat, replace, upper/lower, escape/unescape,
split/join, str_of_bytes, hex_of_bytes, char_at, show_int, JSON string
cells, read_stdin) and every string literal now carries a header, and
`==` / `compare` / `starts_with` compare over the header length instead
of scanning to a NUL. Host glue (`run_wasm.js`, playground) writes the
header for `read_file` / `str_of_float` / `getenv` / arg strings. This
gives the browser mere-ruby playground binary-safe strings (`pack` /
`unpack1` / embedded-NUL `length` now match ruby byte-for-byte)._

---

## v0.1.128 — 2026-08-06

_First native MIDI input capability — the seed of a MIDI dogfood. Six
`extern fn` entry points (`midi_init`, `midi_default_input`,
`midi_open_input`, `midi_poll`, `midi_read`, `midi_close`), backed by a
PortMidi runtime in the C backend. The polling model (`midi_poll` then
`midi_read`) matches the synchronous FFI shape that `tcp_*`/`udp_*` already
use, and a whole MIDI message packs into one int, so — unlike the socket
externs — the read side needs no byte arena._

_The surface is uniformly `int -> int`: the two conceptually-nullary calls
take an ignored dummy `0`. That is not cosmetic — the codegen synthesizes a
first-class closure adapter (`name(__x)`) for every concrete `A -> B` extern,
so a `unit -> int` signature would emit `midi_init(__x)` against a
`void`-param C function and fail to compile. Keeping everything `int -> int`
sidesteps it and matches the arena-FFI convention._

_The PortMidi runtime (and its `#include <portmidi.h>`) is emitted only when
a program declares a `midi_*` extern (a new `uses_midi` gate, mirroring
`uses_tls`), so non-MIDI native builds need no portmidi. Native-C only, like
the socket capabilities; linking asks for `-lportmidi` the same way TLS asks
for `-lssl`. Example: `examples/midi_listen.mere` echoes Note On/Off as note
names (C4, A4, …) with velocity and channel._

_Verified: generated C compiles, links, and runs against a faithful
PortMidi stub — the "no input device" exit path is clean, and a scripted
event stream decodes correctly (Note On C4 vel80, Note Off C4, Note On A4
vel100). The gate excludes portmidi from non-MIDI programs (tcp_smoke: 0
refs)._

---

## v0.1.127 — 2026-08-06

_The Wasm backend's int is now **64-bit** — the receipt from "The Int That
Stayed 32 Bits" came due. The trigger was exactly the documented one: a real
dogfood (a Date.now()-driven clock, and mere-ruby running Ruby arithmetic)
that needs 64-bit integers in the browser. Epoch-milliseconds (~1.75e12)
overflowed i32: the clock trapped at `int_of_float`, and any Ruby snippet
above 2^31 either failed to compile (literals, loudly) or couldn't run._

_The design is the uniform one the receipt named for long-running use: every
value slot widens from 4 to 8 bytes — ints are true i64, pointers carry a
32-bit address zero-extended, wrapped back to i32 exactly at memory
operations, tags/indices/the allocator stay 32-bit internally. The JS
boundary keeps its 32-bit ABI (host imports are declared `$name_h` taking
i32 pointers; generated in-module shims adapt), so hosts stay BigInt-free
except where true i64 values cross: the closure call type
`(param i64 i64) (result i64)` (JS glue passes `BigInt(env)`) and channel
payloads (the ring is now BigInt64)._

_Verified: the four-backend parity suite is **59/0** including three new
int64 cases (big-literal arithmetic, epoch divmod, `int_of_float` above
2^31, 64-bit bitwise); ctest 12/0; self-host fixpoint all-passed; a live
clock prints the correct time on Node; and mere-ruby — a 17k-line Ruby
interpreter — compiles to Wasm (500k lines of WAT), validates, and computes
`1234567890123 + 1` correctly. Also fixed en route: the C backend's
`int_of_float` truncated through a 32-bit `(int)` cast (epoch-ms came out
as `INT_MAX`), and `time` / `print_no_nl` gained Wasm host wiring._

---

## v0.1.115 — 2026-08-04

_Positioned **write** — the write half of the file API, and the forcing
function for an on-disk store (a paged B-tree dogfood, `mbtree`, comes next)._

_`file_pread` (v0.1.83) could read an arbitrary window of a file, but there was
no way to write one: `write_file` / `write_file_bytes` only replace a whole
file. Three new builtins complete random-access file I/O, interp + C only (the
LLVM/Wasm MVP backends have no filesystem and cleanly refuse):_
- _`file_openrw : str -> File` — open a read/write handle, creating the file if
  absent and never truncating an existing one (`r+b`, falling back to `w+b`)._
- _`file_pwrite : File -> int -> Vec[int] -> int` — seek to the offset and write
  the byte vec, extending the file past its end if needed; returns the count
  written._
- _`file_fsync : File -> unit` — flush buffered writes to stable storage
  (`fflush` + `fsync`), for commit points in a durable store._

_`file_pread` and `file_close` now also accept the read/write handle, so a store
reads and writes through one `file_openrw` handle. On the interpreter the handle
is a `Unix.file_descr` (`V_rwfile`); on C it is a single `FILE*`. Round-trips are
byte-identical across interp and C._

---

## v0.1.114 — 2026-08-04

_`contrib/mlint` grows from a one-rule demo into a real linter, and forces a
C-backend codegen fix._

_`mlint` now carries three rules, all as `dyn Rule` trait objects — unused
bindings, unused parameters, and shadowed bindings (the last threading its own
scope environment) — with a two-method trait (`rname` + `check`). It reads a
source path from `args` and lints that file (falling back to a built-in
sample), so it runs on the interpreter and the native C backend; the LLVM/Wasm
MVP backends cleanly refuse `args`/`read_file` (no filesystem)._

_C-backend fix (found by mlint, affects any `dyn Trait`): the arrow-type
collector skipped **polymorphic** records' field types, but the struct emitter
monomorphizes a generic trait dictionary `Trait__dict 'a` (left generic on
`Trait__pack`'s dictionary parameter) at the TyParam-erased default `int`,
emitting `Trait__dict_int`. When a method's field closure type at `'a = int`
(`int -> R`) is instantiated nowhere else, the emitted struct referenced an
undefined C type. `mlint`'s `check : 'a -> program -> diag list` triggered it
(`int -> program -> diag list` appears nowhere else);
`examples/trait_object.mere` compiled only because its `int -> int` /
`int -> str` closures exist elsewhere. Fixed by walking polymorphic-record field
types at their monomorphized instances in `collect_arrow_types`._

_Ergonomics note recorded in `contrib/mlint/README.md`: a trait-object consumer
must annotate its parameter as `dyn Trait` (`fn (ru : dyn Rule) -> …`) to select
object dispatch; an unannotated `fn ru -> check ru …` is inferred with a
`Rule 'a =>` dictionary constraint instead._

_Full suite including the bootstrap fixpoint stays green — 2291 checks, 0
failures. Line-numbered diagnostics remain deferred: the self-host AST is
position-less, and adding spans would ripple through the whole self-host
compiler plus the bootstrap._

---

## v0.1.113 — 2026-08-04

_A linter for Mere, written in Mere (`contrib/mlint`), plus two `contrib/parser`
fixes it forced. `mlint` parses source into the shared self-host AST and runs
lint rules over it — dogfooding the trait system on an AST-sized program: rules
are `dyn Rule` trait objects, diagnostics `derive (Eq, Ord)` for dedup + sort,
and `Ord` is a super-trait of `Eq`. Its one rule so far flags a `let` binding
whose name never occurs in scope; it runs on all four backends._

_Forced upstream in `contrib/parser`:_
- _`parse_program_ast : str -> program` — the parser only exposed
  `parse_str_program` (a debug string); AST consumers (a linter, an analyzer)
  need the `program` value._
- _the parser defined its own `list_append` fixed to `top_decl list`, which
  shadowed the prelude's polymorphic `list_append` for every importer (so
  `list_append` on any other element type failed to type). Renamed the private
  helper to `append_top_decls`._

_(Both are self-host compiler components; the full suite including the bootstrap
fixpoint stays green — 2291 checks, 0 failures.) Recorded pain in
contrib/mlint/README.md: the self-host AST is position-less (message-only
diagnostics), and `type T = Ctor;` — a single nullary variant — parses as a
type alias unless written `type T = | Ctor;`._

## v0.1.112 — 2026-08-04

_Fix a parser declaration-table leak across programs parsed in one process.
`Pipeline.parse_program` reset only `imported_files`, so the constructor /
record / module / alias tables accumulated: a `type Rect = { ... }` record in
one program left `Rect` registered, and a later program's constructor pattern
`Rect r` then mis-parsed as a record pattern (`expected '{' for record
pattern`). This bites any host that parses several programs in one process —
the CI test binary hit it (a `module Shapes { type Rect = {...} }` test
poisoning a later trait-object test's `Rect` constructor), aborting the run._

_`Pipeline.parse_program` now calls `Parser.reset_decl_state ()` once before
parsing the prelude (which re-registers its own types / constructors), giving
each program a clean parser state. The REPL, which drives `Parser.parse_program`
directly to accumulate definitions across lines, is unaffected. Regression test
added; the full test binary now runs to completion (2289 checks, 0 failures)._

## v0.1.111 — 2026-08-04

_Fix an inner-function over-capture on the LLVM and Wasm backends. When a lifted
inner function A calls another lifted inner function B, A's captures are
extended with B's (the transitive-capture closure) so A can forward them. But a
capture of B that is bound *inside A's own body* — a let local, a nested-fn
param, or a match-arm binder — is already in scope in A and must not be threaded
in; otherwise A over-captures, and when A's host calls it the host is asked to
pass a name it never had (`use of undefined value %row` on LLVM, `inner-lifted
capture ``row`` not in scope` on Wasm)._

_The interpreter and C backend already excluded body-bound names (v0.1.48); this
ports that exclusion to LLVM and Wasm. Surfaced by examples/sudoku.mere, whose
inner `cell` (which fills a row) captures the match-arm variable `row` bound in
its enclosing `load` — sudoku now runs on all four backends (previously
llvm:MISCOMPILE / wasm:UNSUP). Locked by
test/parity/inner_capture_match_binder.mere; parity 47/0, unit suite green._

## v0.1.110 — 2026-08-04

_Structural `==` / `!=` and `<` `<=` `>` `>=` on compound values (variant /
record / tuple, including recursive ones like list) now work on the LLVM
backend. Previously the LLVM backend refused structural `==` (a clean UNSUP)
and mis-compiled structural ordering, so a program comparing compounds — e.g.
`deriving Eq/Ord` for a variant key — only ran on interp / C / Wasm._

_Implemented as the LLVM siblings of the C backend's `eq_<tag>` / `cmp_<tag>`
(and the interpreter's `value_eq` / `value_compare`): per-type `define i1
@eq_<tag>` and `define i64 @cmp_<tag>` (returning <0/0/>0) that recurse
structurally over components — extractvalue for tuples/records, tag + boxed
payload for variants (recursive variants via the pointer-to-node layout), and
`strcmp` for strings — matching how `show_<tag>` already walks these shapes.
The Cmp handler lowers `==`/`!=` to a call to `@eq_<tag>` and ordering to
`@cmp_<tag>` compared against 0; the needed types (and their transitive
components) are collected into `eq_types` / `cmp_types` and emitted._

_Effect: deriving `Eq` / `Ord` for a variant or record key now compiles on all
four backends, so ordset over such a key works everywhere. Locked by
test/parity/struct_eq_cmp.mere (variant/record/tuple/list eq+cmp),
derive_variant.mere, and two LLVM-IR test_basic assertions; parity 47/0, unit
suite green. (The interp, C, and Wasm backends already implemented structural
comparison — this brings LLVM to parity, so all four backends now agree.)_

## v0.1.109 — 2026-08-04

_`derive` — generate trait instances from a trait's defaults. `derive (Eq, Ord)
int;` (or single `derive Eq int;`) expands to one empty `impl Ti T {}` per
listed trait; each empty impl inherits the trait's default method bodies. A
trait is therefore **derivable iff every method has a default** — deriving a
trait with a method that has no default is the ordinary "missing method" error._

_This makes structural instances a one-liner: a `trait Eq 'a { eq : 'a -> 'a ->
bool = fn a -> fn b -> a == b; }` (default in terms of the builtin structural
`==`) is derivable for any key type, and `derive (Eq, Ord) int;` gives working
`Eq` / `Ord` instances with no hand-written bodies. Pure sugar over the empty
impl + default-method machinery (v0.1.101); adds the `derive` keyword and works
inside `module` bodies too._

_`contrib/ordset` now carries structural defaults on its `Eq` / `Ord` traits and
`examples/ordset_demo.mere` derives the `int` instances (its `color` key keeps a
custom rank-based ordering). Note: structural `==` / `<` on a variant / record
is still an LLVM-backend limitation, so deriving for such a type works on
interp / C / Wasm but not LLVM (a pre-existing gap, independent of derive).
Locked by test/parity/derive.mere and two test_basic assertions; parity 45/0,
unit suite green._

## v0.1.108 — 2026-08-03

_Trait objects: `dyn Trait`. A heterogeneous collection of values that all
implement a trait, with dynamic dispatch — `[dyn Shape (Circ 2), dyn Shape
(Rect 3)]` is a `(dyn Shape) list`, and a trait method called on a `dyn Shape`
(`area o`) dispatches dynamically. A function that consumes objects annotates
its parameter `fn (o : dyn Shape) -> ...` (a function inferred as `Shape 'a =>`
would instead expect a concrete dictionary-carrying value)._

_Implemented entirely as elaboration, with no new backend support: for an
object-safe trait (every method takes the trait parameter as its single `self`
argument and doesn't otherwise mention it — so `area : 'a -> int` qualifies,
`eq : 'a -> 'a -> bool` does not), trait_elab auto-generates an object record
`Trait__obj` of self-capturing method thunks plus a constrained packer
`Trait__pack`. `dyn Trait e` is sugar for `Trait__pack e`; `dyn Trait` (type)
is sugar for `Trait__obj`; and a method use on a value of object type lowers to
reading and forcing the captured thunk. Because a `dyn Trait` is just a record
of closures, every backend handles it unchanged. Adds the `dyn` keyword._

_This is ergonomic sugar over a pattern already expressible by hand (a record
of self-capturing closures); the sugar removes the per-instance-type
boilerplate. Locked by test/parity/trait_object.mere, two test_basic
assertions, and examples/trait_object.mere (circles + squares in one list on
all four backends); parity 44/0, unit suite green._

## v0.1.107 — 2026-08-03

_Traits and impls may now be declared inside a `module` body. Previously a
module body accepted only `let` / `let rec` / nested `module` (types were
already allowed and kept global); `trait` / `impl` were rejected, so a reusable
trait-based library could not be namespaced. They are now accepted and — like
types — kept global (the module namespaces only its functions), so a consumer
writes bare `impl Ord T` but calls `M.of_list`. The top-level trait/impl
parsing was factored into shared helpers used by both the top-level and
module-body parsers._

_Also fixes a spurious non-exhaustive-match warning for a `type` declared
inside a module: the module qualifies constructor uses (`M.Leaf`) but the
variant registry keys on the bare name, so the exhaustiveness checker now
normalizes a qualified constructor to its bare last segment before comparing._

_Surfaced by the `contrib/ordset` dogfood — a generic sorted set (BST) over an
`Ord` key, with a consumer (`examples/ordset_demo.mere`) that instantiates it at
`int` and a user-defined `color` variant. The dogfood also hit a pre-existing
limitation (a top-level polymorphic value binding like `empty = Leaf : 'a tree`
has no use site to fix `'a` and is rejected by the LLVM backend), worked around
in the library by exposing `empty` as a thunk. Locked by
test/parity/trait_in_module.mere and a test_basic assertion; parity 43/0, unit
suite green._

## v0.1.106 — 2026-08-03

_Extend v0.1.105's local-fn duplication to a single self-RECURSIVE local
`let rec f = fn ... in body` used at several concrete types. Each type gets its
own monomorphic copy, and the recursive self-call inside each copy is redirected
to that copy, so the C and LLVM backends compile it (LLVM previously refused).
The transform requires that `f` is not shadowed in either its body or its
continuation, which keeps the self-call rename unconditional and safe. Mutual
(multi-binding) local `let rec` groups used at several types are still left
alone — a rarer remaining case. Locked by
test/parity/local_poly_rec_multi_type.mere; parity green, unit suite green._

## v0.1.105 — 2026-08-03

_A LOCAL polymorphic function used at several distinct concrete types now
compiles correctly on the C and LLVM backends (`let id = fn x -> x in
(id 1, id 1.5)` and friends). Both backends lift a local function to a single
top-level function, so a multi-type use previously defaulted it to one type and
miscompiled on C, or was refused on LLVM. The interpreter and Wasm already
handled it._

_Fix: a pre-pass (`duplicate_multi_use_local_fns`) that, before lifting, splits
such a local binding into one monomorphic copy per distinct concrete use type
and rewrites each use to its copy — turning the unsolved "multi-instantiate a
lifted local fn" problem into the already-solved monomorphic case for every
backend. It is deliberately conservative: it fires only on a non-recursive
local `let` (nested inside a function body, so top-level functions are left to
the ordinary multi-instantiation machinery), only when the function is not
shadowed and every use is at a concrete type. Implemented once and shared by
both native backends._

_Locked by test/parity/local_poly_multi_type.mere (int / float / bool) and
local_poly_multi_type_hof.mere (a higher-order local fn at two types); parity
39/0, unit suite green. Still open: the recursive local case and top-level
mutually-recursive functions used at multiple types._

## v0.1.104 — 2026-08-03

_Constrained recursive functions in a LOCAL `let rec ... in` — self- and
mutually-recursive — now work. Previously only top-level `let rec` groups were
handled; a local one failed with "ambiguous trait constraint". Two changes: the
typer now records a local `let rec` binding whose scheme carries trait
constraints into `trait_local_constrained` (it already did this for a local
non-recursive `let`), and trait_elab threads the group's shared dictionary
through every intra-group reference of a local `let rec` group, mirroring the
top-level handling._

_The C and LLVM single-use monomorphization pass is extended to local `let rec`
groups so a local constrained recursive function used at a single non-int type
(e.g. float) emits at that type instead of defaulting to int. This is
restricted to dictionary-taking (trait-constrained) members and excludes each
member's own body from the use scan, so it cannot mis-specialize a genuinely
polymorphic recursive function used at several types (e.g. the prelude's
`list_fold`)._

_Works on all four backends at a single instance type (int / float / user
variant). Locked by test/parity/trait_local_rec_self.mere,
trait_local_rec_mutual.mere and two test_basic assertions; parity 39/0, unit
2283/0. (A local polymorphic recursive group used at several distinct types
remains gated by the same pre-existing multi-instantiation limit as top-level
and trait-free polymorphic recursion.)_

## v0.1.103 — 2026-08-03

_Super-traits: `trait Ord 'a : Eq 'a { ... }`. A super-trait declares that any
instance of the sub-trait must also be an instance of the super-trait. `impl
Ord T` now requires `impl Eq T` (checked transitively, and for every super in a
multiple-super list `: Eq 'a, Show 'a`); omitting it is a clear error rather
than a confusing failure at a later use site._

_Method access needs no special dictionary machinery: Mere's inference records
a separate constraint for every trait method actually used, so a generic
function that uses both an Ord method and an Eq method on one value already
receives both dictionaries (there are no signature-level constraint annotations
that could under-specify this). This is why super-traits reduce, for Mere, to
the declaration plus the well-formedness guarantee._

_As part of this, impl method bodies are now type-checked at their concrete
instance type (`param := target`), so an impl body that calls another trait's
method on the instance value — e.g. a super-trait method — resolves to that
trait's concrete dictionary instead of leaving an unresolved dispatch variable.
(Same-trait sibling calls are still inlined before type-checking, so no
self-referential dictionary arises.) Locked by test/parity/trait_super.mere and
three test_basic assertions; parity 37/0, unit suite green._

## v0.1.102 — 2026-08-03

_Support top-level mutually-recursive constrained functions (a `let rec f =
... and g = ...;` group where the members require a trait). This used to be
rejected ("mutually-recursive constrained function ... is not yet supported")._

_Intra-group references are typed monomorphically (before generalization), so
they carry no constrained-use obligation and must be threaded by hand: a
reference to a constrained group member — itself or a sibling — is applied to
the dictionary parameter(s) that member expects. Because the group is typed
monomorphically, mutually-recursive members share the dispatch variable(s), so
those dict parameters have the same names as the current member's own and are
in scope. This generalizes the single self-recursive case (which becomes the
one-element instance of the same code path)._

_Scope: a single instance type works on all four backends. A polymorphic
mutual-rec group used at two distinct types hits a separate, pre-existing
backend multi-instantiation limitation (it fails the same way for trait-free
mutually-recursive polymorphic code). Local (`let rec ... in`) constrained
recursion — self or mutual — remains a distinct open path. Locked by
test/parity/trait_mutual_recursion.mere and two test_basic assertions; parity
36/0, unit suite green._

## v0.1.101 — 2026-08-03

_Trait method DEFAULTS, and impl method bodies that reference sibling methods.
A trait method may now be written `m : ty = expr`; an impl that omits `m`
inherits that default. Both this and an impl body that calls a sibling method
(e.g. `neq = fn a -> fn b -> if eq a b then ...`) previously failed — the
sibling reference had an unresolved dispatch type ("ambiguous trait
constraint"), and resolving it to a dictionary field would have required the
dictionary to reference itself, which Mere has no way to express._

_Both are solved the same way: trait_elab completes each `impl Trait T` before
any type-checking — every method gets a source body (the impl's own, else the
trait default, else a "missing method" error), and every reference to a sibling
method name inside a body is replaced by that sibling's (recursively inlined)
source body. Cyclic defaults are rejected. After completion each method is a
self-contained body with no trait-method name references, so type inference
sees ordinary Mere and the dictionary stays a plain, non-recursive record —
every backend is unchanged. An impl may still override a default by providing
the method. Locked by parity cases trait_sibling_method.mere /
trait_default_method.mere and five test_basic assertions; parity 35/0,
unit 2277/0._

## v0.1.100 — 2026-08-03

_Fix a dictionary mix-up when a generic function carries two trait constraints
on the SAME type variable (e.g. `(Num 'a, Sh 'a) => 'a -> str`). The
elaboration's variable→dict-parameter map was keyed by the type variable's id
alone, so the second constraint's dictionary parameter clobbered the first —
and a `Num` method use resolved to the `Sh` dictionary, failing with
"record Sh__dict has no field: add"._

_Fix: key the map by (variable id, trait). Since `resolve_dict` already knows
which trait a method belongs to, each method use now selects the correct
dictionary. A function constrained by multiple traits on one variable
elaborates and runs correctly on all four backends. Locked by the parity case
`trait_multi_constraint.mere` and a `test_basic` assertion; parity 34/0, unit
2272/0._

## v0.1.99 — 2026-08-03

_Monomorphize single-use local polymorphic functions on the C and LLVM
backends. A local `let f = fn ... in ...` is let-generalized by the typer, so
its binding keeps an unresolved scheme while each use site instantiates a fresh
concrete copy. Both native backends lift such a local fn to one top-level fn
and default its residual type variable to `int` — so a local fn whose sole use
is at, say, `float` was emitted as an int-typed C function and the float call
site mismatched at compile time. (The interpreter and Wasm already handled the
general case.) This is the long-standing "local polymorphic fn not
multi-instantiated" limitation that the v0.1.98 trait local-`let` support ran
into — reproducible without traits._

_Fix: a whole-program pre-pass (`specialize_single_use_local_fns`) run before
fn-type resolution and inner-fn lifting. When a local fn is used at exactly one
concrete type, it unifies the binding type with that use arrow; because the
body's type variables are shared mutable union-find cells, this propagates into
the body, so the lifted fn AND any generic callee inside it (e.g. `list_fold`)
resolve concretely. Running before `resolve_fn_types` is essential — the
top-level multi-instantiator only sees a generic callee's concrete use once the
enclosing local fn's body is concrete (cf. the v0.1.28 poly-through-poly fix)._

_Effect: a constrained generic function defined in a local `let` now compiles
on all four backends at any single instance type — `int`, `float`, or a
user-defined variant. Multiple distinct use types on one local fn are left to
the existing defaulting (a larger multi-instantiation increment). Locked by the
trait-free-equivalent parity cases `trait_local_let.mere` (int) and
`trait_local_let_variant.mere` (user variant); the four-backend differential
harness stays 33/0 and the unit suite 2271/0._

## v0.1.91 — 2026-07-31

_Real TLS on the native backend: `tcp_starttls` / `tcp_starttls_verified` are
no longer stubs. Declaring either extern swaps in an OpenSSL-backed runtime —
`tcp_starttls` does the handshake with SNI; `tcp_starttls_verified` adds peer
certificate verification and hostname matching (with an optional CA-bundle
path) — and `tcp_read` / `tcp_write` / `tcp_close` route through the per-fd
`SSL*` when a socket has been wrapped, so the rest of a client is unchanged
between HTTP and HTTPS. The whole thing is gated on a `uses_tls` flag set only
when a program declares a starttls extern: a plaintext TCP program emits zero
OpenSSL references and still links with just `-lm`, so TLS's external
dependency is opt-in. A TLS program compiles with, e.g.,
`-I$(brew --prefix openssl@3)/include -L.../lib -lssl -lcrypto`.

Surfaced and verified by the mhttps dogfood — an HTTPS GET client in pure Mere:
it fetches `https://example.com/` and `https://api.github.com/` (the latter
requiring a valid verified handshake) and prints `HTTP/1.1 200 OK` for both.
test_basic guards that starttls pulls in the OpenSSL runtime and that a
plaintext program does not. TLS on the Wasm host is still separate (browsers do
TLS transparently); native LLVM shares the C runtime. suite passed._

## v0.1.90 — 2026-07-30

_`mere install` detects same-major version conflicts instead of silently
picking one. A module path may resolve to only one revision in a build; if two
packages in the dependency graph demand the same path at different revs, the
installer used to fetch both and let the second overwrite the first
(last-writer-wins). It now tracks the resolved sha per module path and fails
with both revisions named, asking for explicit reconciliation (pin it in the
top-level mere.toml). This is the correct answer for Mere's model: it pins
exact revisions with no version ranges, so there is nothing to minimize over —
the npm/cargo MVS problem does not arise. Incompatible majors sidestep the
conflict entirely by living at different module paths (`.../v2`, SIV, v0.1.89),
which the check leaves untouched (distinct paths → no conflict). Together with
v0.1.88–89 this closes the version-resolution axis of Q-013 for an exact-pin
package manager. Hand-tested against a diamond (two libs pinning the same
library at different revs → conflict; the SIV app with distinct paths →
installs clean). suite: 2255 passed / 0 failed._

## v0.1.89 — 2026-07-30

_Two `module`s with the same name now coexist correctly on every backend —
the language-side half of Go-style Semantic Import Versioning (SIV). A library
and its `/v2` (an incompatible major) both name their module the same
(`module Greet { ... }`), so their members desugar to identically-qualified
top-level names (`Greet.hello` defined twice, of different types) that shadow
by declaration order. The interpreter already honoured that — a closure
captures the env at its definition and the env prepends, so a reference binds
to the most-recent prior definition — but the native backends resolve a
top-level name globally and mis-assigned one version's body to the other (a C
build emitted `Greet.hello : str -> str` with the *other* version's
closure-returning body). New pipeline pass `Ast.uniquify_toplevel_module_shadows`
walks the decls in order and, when a **dotted** (module-qualified) name is
redefined, alpha-renames the redefinition (`Greet.hello` → `Greet.hello__v2`)
and rewrites later references, so all four backends see distinct symbols.
Only dotted redefinitions are touched, so ordinary programs are unaffected.

Verified with the version-resolution dogfood — an app whose two dependencies
pull incompatible majors of a shared library via SIV distinct paths
(`.../mgreet` and `.../mgreet/v2`): it now prints the v1 and v2 results
side by side on interp, C, LLVM, and Wasm. This closes the native gap that the
dogfood surfaced; combined with the full-path installer (v0.1.88), SIV works
end to end. Minimal-version selection (MVS, for compatible same-major demands)
remains the one deferred package axis. suite passed._

## v0.1.88 — 2026-07-30

_`mere install` grows up to match the Go-style import model (Q-013): full-path
layout, cross-repo transitive resolution, and a verifying lockfile. Driven by
the first genuinely multi-repo dogfood — a 3-repo transitive graph
`mcalc → mbigfmt → mbignum` where the app never names the leaf. Three gaps
surfaced and were fixed:_

- _**Full-path layout.** Installs went to `.mere_modules/<bare-name>/`, but a
  Go-style import resolves to `.mere_modules/github.com/owner/repo/`, so even a
  direct dependency failed to resolve. The installer now reads each fetched
  package's own `mere.toml [package] path` and installs under it (bare-name
  fallback for legacy packages)._
- _**Cross-repo transitive deps.** The installer only followed `../` relative
  imports (monorepo siblings); a dependency declaring its own `[dependencies]`
  in another repo was never followed. It now reads each fetched package's
  `[dependencies]` and queues them, so transitive cross-repo deps are pulled in
  (deduped on the `(git, rev, subdir)` coordinate for diamonds)._
- _**Verifying lock.** `mere.lock` already recorded resolved shas + content
  hashes; now a re-install parses the existing lock and, if a pinned
  `(git, rev)` coordinate produces a different hash, fails loudly (go.sum-style
  tamper/corruption detection) instead of silently building against changed
  content._

_The resolved lock records the full transitive graph, so `mcalc`'s lock pins
`mbignum` even though `mcalc` only depends on `mbigfmt`. Verified end-to-end:
`mcalc fact/fib N` matches python on interp and C, reading both deps out of the
full-path `.mere_modules/`. Unit tests cover the `[package] path` parse and the
write_lock/read_lock round-trip; the fetch path is git-integration-tested by
hand. suite: 2248 passed / 0 failed._

## v0.1.87 — 2026-07-29

_A user top-level binding named `main` now compiles on every backend
(finishing the follow-up left open in v0.1.86). Mere has no `main`
convention — the entry point is the file's trailing expression — so a `main`
binding is just an ordinary value that happens to share the synthesized
entry's name. The C backend already mangled it (`mu_main`), but LLVM and Wasm
emitted the raw name and hit a duplicate-`main` link/assemble error. Rather
than patch each backend, the fix is one backend-agnostic pass in the pipeline:
`Ast.reserve_toplevel_main` alpha-renames a top-level `main` to a reserved
name (`__mere_user_main`) via the existing scope-aware `rename_free_vars`, so
an inner `main` (a local let or a parameter) still shadows and is untouched.
Verified: `let main = fn () -> 42 in main ()` prints 42 on interp, C, LLVM,
and Wasm. The v0.1.86 note's "not fixed" caveat is superseded. suite passed._

## v0.1.86 — 2026-07-29

_`str_eq` on the LLVM backend. The interpreter and C backend had string
equality, but the LLVM backend never defined it, so any LLVM-compiled program
using `str_eq` failed at emit with "unbound variable: str_eq" (surfaced by the
bignum and mpath dogfoods, both of which pattern on single characters). The
2-arg call now lowers to a new `@__lang_str_eq` runtime — a byte compare over
two NUL-terminated strings returning i1 — mirroring the C backend's strcmp
path. Guarded in test_basic; verified equal/unequal/empty/prefix cases match
the interpreter on a compiled LLVM binary.

Not fixed here (documented in the mpath dogfood's PAIN): the Wasm backend emits
a user top-level binding named `main` as `$main`, colliding with the exported
entry `$main` ("redefinition of function $main"). It is narrow (only a literal
`main` binding, only on Wasm) with a trivial rename workaround; a proper fix
mangles or reserves the entry name and is left as a follow-up. suite passed._

## v0.1.85 — 2026-07-29

_A module-level value binding compiles on the C backend, and a new
`contrib/bignum` library. Writing bignum surfaced the bug: `let base =
1000000000` inside `module Bignum { ... }` carries a dotted name (`Bignum.base`),
and the C let-emitter used the raw binder name for its internal temporaries,
so it emitted `__auto_type __let_tmp_Bignum.base = ...` — a `.` in a C
identifier, which does not compile. Every earlier contrib module bound only
functions (whose names already route through name-mangling), so a module
*value* binding had never been exercised. Fix: flatten the dot for the
`__let_tmp_` / `__let_result_` temp names (`Bignum__base`); ordinary
undotted names are untouched, so only the previously-broken module-value case
changes. Guarded in test_basic.

`contrib/bignum/bignum.mere` is a reusable arbitrary-precision natural-number
library — little-endian base-1e9 limbs as a persistent `int list`
(from_int / add / mul_small / mul / cmp / to_str / fact / fib). Base 1e9
keeps limb products under 2^63 on the 64-bit backends. `examples/bignum_demo.mere`
imports it by full path and prints 100!, fib 200, and a product that match
python's bignum exactly on interp and C. Backend reach: interp + C exact;
Wasm runs add/fib but mul overflows its 32-bit int (a base-1e9 product is
~1e18); LLVM rejects a polymorphic inner-closure capture (a known
monomorphization gap) — both documented in the library README. suite: 2244
passed / 0 failed._

## v0.1.84 — 2026-07-29

_Fire-and-forget threads: `detach : ThreadHandle -> unit`. `spawn` returns a
joinable handle, and the only way to reclaim a worker's resources was
`join`, which blocks. A server's accept loop that spawns one handler per
connection and never joins therefore leaked a joinable thread per
connection, so a long-running server slowly exhausted thread resources.
`detach h` releases the thread without waiting for it (pthread_detach on the
C backend; a no-op on the reference interpreter, whose domains are not the
server target). Surfaced by the mhttpd dogfood (a concurrent HTTP/1.1
server): with detach plus a fixed pool of arena buffers handed hand-to-hand
over a channel, mhttpd serves 400 sustained concurrent requests where the
naive version aborted at ~256 (each connection had leaked a fresh 64 KB from
the no-free byte arena). No new limitation in the byte arena itself — its
loud abort-on-exhaustion already told the server to pool and reuse buffers;
detach is the missing concurrency primitive. suite passed / 0 failed._

## v0.1.83 — 2026-07-29

_Positioned reads: `file_pread : File -> int -> int -> Vec[R, int]`.
`file_pread handle offset len` seeks to `offset` and reads up to `len` bytes
from an open handle, returning them as an int vec (same byte representation
as read_file_bytes). Reads fewer than `len` bytes only at EOF (partial
tail). Until now the only binary read was `read_file_bytes`, which loads the
whole file — fine for a WASM module inspector, useless for a random-access
format where the point is to touch only the pages you need. This is the
capability a B-tree file format wants: read one page at an offset without
paying for the whole file. Interp uses seek_in/really_input on the
in_channel; the C backend emits `__lang_file_pread` (fseek + a bounded fgetc
loop building a region vec_int). Scope is interp + C, inheriting the file
I/O family's boundary — a program that preads first opens the handle with
file_open, which already refuses cleanly on LLVM/Wasm ("v0.1.59 scope =
interp + C"), so file_pread needs no separate unsupported arm there.
Surfaced by the msqlite dogfood (a read-only SQLite reader): it now prints
`SELECT * FROM t` byte-for-byte against sqlite3 on both interp and C,
reading the header, sqlite_master, and a table's leaf page by positioned
reads. suite: 2242 passed / 0 failed._

## v0.1.82 — 2026-07-29

_The LLVM backend's region allocator grows the arena instead of overrunning
it. `__lang_region_alloc` was a pure bump — add the aligned size to the top
pointer and return, with no bounds check — so once the default 4 MB arena
filled, allocations ran past the malloc'd buffer and corrupted the heap. An
allocation-heavy program (a per-pixel renderer that materializes a float
triple per pixel) crashed with SIGSEGV at larger image sizes on LLVM while
interp, C, and Wasm all produced the same checksum; the C backend had gained
bounds-checked, block-chained growth in v0.1.25 (found by a long-running
server) but the LLVM runtime never received it. The LLVM `%__lang_region`
struct now carries a 4th `blocks` field (a chain of malloc'd blocks, each with
a 16-byte header holding the `prev` link so the data that follows stays
16-aligned); `__lang_region_alloc` compares `top + aligned` against
`base + cap` and, when it would overrun, chains on a geometrically larger
block (doubling until it fits) via a new `__lang_region_add_block` helper;
`__lang_region_init` seeds the first block and `__lang_region_free` walks the
chain. Blocks never move, so pointers into earlier blocks stay valid across
growth — matching the C semantics exactly. New guard
`test/parity/region_growth.mere` folds a checksum over ~6 MB of live region
allocations (two shallow loops so it exercises arena growth, not stack depth)
and now matches across all four backends. Guard verified by reverting the
fix: the LLVM column goes DIFF (empty output from the crash) on the old
allocator and returns to MATCH with the growth in place. suite: 2240 passed
/ 0 failed; parity 28/28 (was 27)._

## v0.1.81 — 2026-07-29

_Go-style full-path imports adopted in-repo: the self-host resolver learns the
module path, and contrib's cross-package imports migrate. v0.1.80 taught the
OCaml resolver to resolve an import under the project's declared module path
(`mere.toml [package] path`) to local files; but the self-host toolchain has
its own import inliner (`inline_imports_in` in contrib/codegen), whose
`resolve_import_path` only knew base-dir-relative resolution — a first
migration attempt made the self-host tests fail with a doubled path
(`contrib/eval/github.com/.../ast.mere`). `resolve_import_path` now mirrors
the OCaml resolver with its signature unchanged: an import whose first segment
looks like a host name (contains a dot, not dot-relative) walks up from the
importing file probing for a mere.toml that declares a matching module path
and resolves module-root-relative; anything else keeps the historical
behavior, and plain relative imports never probe. A missing mere.toml reads
uniformly as "" on every backend (the language-level read_file fails catchably
under try_or on interp/C; the Wasm host returns an empty string — its ENOENT
log is now silent since a miss is an expected probe result). The helpers
follow the file's Phase 54.32 style (inner loops hoisted to top-level rec fns
with explicit args, the wasm-codegen capture workaround). With that in place,
the repo declares `path = "github.com/merelang/mere"` in a root mere.toml and
contrib's 11 cross-package `../` imports (typer/fmt/codegen/eval -> parser,
http -> log, feed -> xml, site -> markdown/path, webhook -> http) migrate to
full-path spelling — the same import now works in-repo (module-path-local) and
vendored (`.mere_modules/<full-path>/`). site/playground keeps its own build
pipeline untouched. suite: 2238 passed / 0 failed; self-host bootstrap
fixpoint all-passed; ctest 12/12; parity 27/27._

## v0.1.80 — 2026-07-29

_Module-path-local resolution for Go-style full-path imports (Q-013, compiler
side). A project declares its module path in `mere.toml` (`[package] path =
"github.com/owner/repo"`); the OCaml resolver walks up to the nearest such
mere.toml and resolves an import that starts with the declared path to local
files relative to the module root. External consumers already resolved
full-path imports via `.mere_modules/<full-path>/` (the walk-up resolver
handled deep paths unchanged) — this adds the in-repo half, so a package's
cross-package imports use the same spelling in-repo and when vendored.
Resolution order: module-path-local, importer-relative, `.mere_modules`
walk-up, `-I`/MERE_PATH; a project with no declared path is unaffected. Two
unit guards; packages.md documents the convention. suite: 2238 passed / 0
failed._

## v0.1.79 — 2026-07-28

_Doc-only: memory-model.md documents the heap-element overwrite leak in
copy-on-store containers (a hot loop overwriting the same `vec_set`/`map_set`
slot with fresh strings grows O(writes) — the container region is
bump-allocated, so old copies are unreclaimable; measured ~550 MB for 4M
overwrites; scalar elements unaffected). Eliding the copy needs type-level
region tracking on `str` (deferred); prefer scalar slots or StrBuf reuse in
hot-overwrite loops._

## v0.1.78 — 2026-07-28

_A race/cancellation example, and the finding that the structured-concurrency
"select" gap is smaller than assumed. `channel_recv_timeout ch 0` turns out to
be a general non-blocking try-recv (empty -> None, ready -> Some, verified on
interp and C), which makes poll-based select and cooperative cancellation
expressible with the primitives already in the language: examples/race.mere
spawns N workers, takes the first to finish via a shared results channel, then
broadcasts one cancel token per worker that each worker observes with a 0-ms
recv on every step and stops early. So the only genuinely-missing piece of E-1
is a *blocking* multi-channel select (an efficiency win over busy-polling), not
a capability gap — it stays deferred. (channel_recv_timeout is interp+C scope,
v0.1.48, so the example is interp+C; LLVM/Wasm report it cleanly unsupported.)
No compiler change. suite: 2236 passed / 0 failed._

## v0.1.77 — 2026-07-28

_Map-accumulator memory fix (C backend), surfaced by a word-frequency dogfood.
Counting words into a `Map[str, int]` over a 37.6 MB file with only ~13
distinct words held 62.5 MB of RSS — O(file), not O(distinct keys). Isolated to
`map_set`: copy-on-store (v0.1.30) deep-copied the key into the map's region
UP FRONT, before the hash lookup, so every update to an existing key leaked one
key copy into the never-reclaimed bump region. A pure churn of 8M sets over 3
keys reproduced it (62.5 MB). The fix copies only what is actually stored: hash
and key comparison use the caller's (content-identical) key, an existing-key
update copies just the new value, and only a fresh insert copies the key. Churn
and word-count both drop to ~1.3 MB (~45x), same output. This is the ubiquitous
counter / histogram / accumulator pattern (a KV server, a frequency table),
previously O(total writes). LLVM and Wasm were already flat here (they do not
copy-on-store). Added an in-process guard that the key copy sits after the
lookup loop. suite: 2236 passed / 0 failed._

## v0.1.76 — 2026-07-28

_More parity coverage (test/parity/ 22 -> 26) and a documented known
divergence. Added four shapes that agree across all four backends: an
or-pattern match arm with a shared binding, functional record update
(`{ base | f = e }`), float builtins with int_of_float, and a variant whose
constructors carry different payload shapes. Probing the divergence-prone
corners recorded their status: a nested let-record/constructor pattern
(`let pt { x = a } = p`) is a parser limitation (rejected before codegen, not a
backend gap); `ref`/`:=` mutable cells are not a Mere idiom. One genuine but
already-known correctness divergence was reconfirmed and is deliberately NOT in
the pass/fail corpus (it would be a permanent red): a 64-bit integer
computation (`100000 * 100000` = 10^10) is correct on interp and C but
silently wrong on LLVM and Wasm, whose integers are i32 — the documented
i64-widening limitation (a non-goal per the earlier LLVM assessment). No
compiler change. suite: 2235 passed / 0 failed._

## v0.1.75 — 2026-07-28

_Port the v0.1.70 referenced-but-unresolved poly-fn recovery to the Wasm
backend. A polymorphic helper whose arrow keeps a residual type variable at
every use site (e.g. `result_and_then` applied only to `Ok`, so the error type
never grounds) is dropped by the resolver as unused — but if emitted code still
references it, the direct call site emits `call $<name>` to a function that was
never defined, which C fixed in v0.1.70 but Wasm still hit, producing an
invalid module (`undefined function variable "$result_and_then"`). The parity
harness (v0.1.73) surfaced it. Wasm's `resolve_fn_types` now runs the same
recovery fixpoint C does: after the normal resolution, scan the emitted spine
(`Codegen_c.find_live_arrow`, which accepts arrows with tyvars and skips
dropped fn definitions) for live references to still-unresolved skels, and emit
each with `Codegen_c.deep_erase_tyvars` erasing residual tyvars to int (both
helpers are backend-agnostic and reused directly). The unconstrained-error
`result` program now emits a valid module and runs on Wasm (== interp/C == 42);
LLVM continues to report it a clean codegen error (documented subset limit).
Added test/parity/result_residual.mere and an in-process guard asserting the
Wasm definition is emitted, not just called. suite: 2235 passed / 0 failed._

## v0.1.74 — 2026-07-28

_Parity corpus expansion (test/parity/ 9 -> 21) plus a harness classification
fix. Added twelve diverse self-contained programs — nested tuple pattern,
prelude option/result/list helpers, nested-variant match, string/char ops,
curry-3, value shadowing, negative div/mod, tuple-capturing closure, boolean
short-circuit — each run through all four backends. All 21 now agree with the
interpreter. Two backend divergences surfaced along the way: (1) a nested
let-tuple pattern (`let ((a,b),(c,e)) = t`) is rejected by C, LLVM, and Wasm
with a clean "not supported in <backend> codegen subset — use match" (a
consistent, documented limitation); the harness's emit-classifier now
recognizes that phrasing as UNSUP rather than a hard failure, so it is not a
false red. (2) A prelude `result` helper left with a residual (error) tyvar —
only `Ok` used, so the error type never grounds — makes the Wasm backend emit a
`call` to an undefined function (invalid module), where the C backend recovers
it (v0.1.70) and LLVM errors cleanly; the corpus uses a fully-concrete
`(int, str) result` instead, and the Wasm gap (it should recover like C or
error like LLVM, not emit an invalid module) is recorded for a follow-up. No
compiler change. suite: 2234 passed / 0 failed._

## v0.1.73 — 2026-07-28

_A four-backend differential (parity) harness — `scripts/parity.sh` +
`test/parity/` — plus the resolver bug it immediately caught. The harness runs
each program through every backend (interp / C / LLVM / Wasm) and diffs stdout
against the interpreter, classifying each backend MATCH / DIFF / MISCOMPILE /
UNSUP (clean "unsupported" at emit) / SKIP (toolchain absent). It exists to
catch the "interp-accepts / backend-rejects" and "backends-disagree" family
before a dogfood stumbles on it. On its first run it found one: a top-level fn
named `f` taking a tuple and matching on it compiled on interp / LLVM / Wasm
but MISCOMPILEd on C. Root cause: the concrete-arrow discovery that drives
per-instantiation monomorphization (find_concrete_arrow /
find_all_concrete_arrows_in / find_live_arrow) walked into the bodies of
resolved poly helpers ignoring binder scope — so list_fold / list_map's
parameter `f` was read as a use of the user's top-level `f`, forcing a bogus
`int -> int -> int` monomorphization that treated the tuple parameter as
curried (`.f0` / `.f1` on a scalar). The fix makes those scans skip a `Fun`
parameter that shadows the searched name; only the Fun binder is treated as
shadowing, because a let / let-rec binding the name may itself be the poly fn's
definition whose use sites live in its body (narrowing to Fun keeps chained
multi-instantiation discovery working). This is the same name-collision family
as the earlier `index` / `y0` param cases, but in the monomorphizer rather than
name mangling. Added a corpus of nine self-contained parity programs
(arithmetic, recursion, let-pattern, tuple/ADT/record match, closures, strings,
mutual recursion) and an in-process guard for the fixed mono. suite: 2234
passed / 0 failed._

## v0.1.72 — 2026-07-28

_`contrib/stream` — region-scoped line streaming combinators, closing the
ergonomic side of the strings-lifetime gap. A `str` carries no region tag, so
the escape checker must assume any line read in a streaming loop may escape and
keeps it in the program-lifetime region; a naive line loop therefore grows to
O(file). The reclaim machinery to avoid this has existed since v0.1.31 (a
`region R {}` block redirects the thread-local current region, and an
escape-clean block result — an int/bool/unit — is copied out while the block's
scratch, including the line string, is freed on release), and the memory-model
doc measured it, but there was no reusable combinator, so a streaming tool had
to hand-roll the per-line region (mgrep's line loop simply didn't, and grew to
~file size). `module Stream { each_line, count_lines }` packages the pattern:
`each_line path cb` runs a side-effecting `str -> unit` callback per line, and
`count_lines path pred` returns a match count, each processing the line inside
a per-line region block. Measured on a 57 MB / 1,000,000-line input, native C
backend: peak RSS 61.7 MB (naive loop) -> 1.4 MB (combinator), a 44x drop, same
output. Added examples/stream_lines.mere and an in-process codegen guard
asserting the region redirect -> file read -> restore -> release ordering that
makes the reclamation hold. The deeper fix — a type-level region tag on `str`
so region-scoped strings can also be stored into outer containers — remains
deferred until a dogfood forces it (the streaming case, which is what has
recurred, is covered by this). Backends: interp + C (per-line file input is not
implemented on Wasm/LLVM). suite: 2233 passed / 0 failed._

## v0.1.71 — 2026-07-28

_C-backend hardening: two latent "compiles-to-C-then-fails" bugs fixed, plus
the missing compile-and-run test path that let this family recur. (1) The
`_as_value` closure adapter every top-level fn gets now sanitizes its
parameter name through `c_safe_name` — a source parameter named like a C
keyword (`case`, `default`) previously emitted an invalid C parameter
declaration in the wrapper even when the fn was never used as a value, since
wrappers are generated for all top-level fns. (2) An extern used in value
position (passed to a higher-order fn, not directly applied) now lowers to a
closure adapter `__ext_<name>_as_value` that calls the raw FFI symbol, instead
of the mangled `mu_<name>` (undeclared — a bare extern is a raw C function,
not a closure struct). This is the reference-side twin of the v0.1.61 capture
fix; restricted to a simple `A -> B` signature, a curried/higher-order
extern-as-value is now a clear compiler error pointing at `fn x -> name x`.
(3) `scripts/ctest.sh` + `test/ctests/` add a native-backend compile-and-run
differential harness: each program is emitted to C, compiled with the C
compiler, and (for extern-free programs) run and diffed against the
interpreter; it also emits Wasm and assembles it with wat2wasm when available.
The in-process suite only ever inspected the emitted C as text, so
undeclared-identifier and closure-type failures escaped it; the harness
compiles the emitted code for real. The corpus covers the family across both
backends — reserved-name/keyword params, extern-as-value and extern-in-closure,
top-level-fn-as-value, inner recursive uncurrying, mutual recursion, tuple
capture, and multi-variable/deeply-nested captures (the Wasm backend, whose
identifiers can't collide with C keywords and which already errors cleanly on
extern-as-value, was confirmed free of the two C miscompiles). Two in-process
string guards for the fixed regressions were also added. suite: 2232 passed /
0 failed._

## v0.1.70 — 2026-07-27

_A referenced-but-never-concretized poly fn is now emitted (tyvars erased)
instead of silently dropped. `resolve_fn_types` treated every fn without a
concrete arrow as unused and skipped it — but a fn whose arrow keeps a
residual tyvar at every use site (e.g. an unannotated wrapper taking a
producer whose result is the bottom type of an endless loop) is NOT dead:
call sites still emit a direct call, which failed at the C compile with an
undeclared identifier. The fix is a recovery pass after the resolution
fixpoint: scan the emitted spine — the program expression minus top-level
fn definitions, plus the bodies of emitted and recovered fns (their own
fixpoint) — for live references, and emit such fns with `deep_erase_tyvars`
(residual tyvars become int, the representation the v0.1.69 emission
erasure already names). The liveness scan must skip fn-definition bindings:
scanning the whole expression would resurrect every generic prelude helper
referenced from other dropped helpers' bodies. Downstream, the type-
instance collectors learned the same erasure so recovered generic bodies
register the instances their erased emission references: Channel / Vec /
OwnedVec / Map element types erase before the concrete gate in c_type_of,
and tuple-shape / mono-variant collection registers erased shapes (dead
extras dedup by name). An unannotated polymorphic generator wrapper called
with an endless producer now compiles and runs end-to-end. suite: 2230
passed / 0 failed._

---

## v0.1.69 — 2026-07-27

_Residual type variables are erased at C codegen instead of rejected. A
type variable that survives to codegen is either dead — the bottom result
of a function that never returns, such as an endless generator loop — or
genuinely unconstrained; no operation ever inspects such a value, so any
representation works. `ty_tag` now names it `int` and `c_type_of` emits
`long long` (the representation the resolver's use-site naming already
assumes), instead of raising "unsupported C codegen type element: 'a".
This fixes two failures found by a concurrency probe: an endless producer
(`let rec go = fn a -> fn b -> ... go b (a + b)`) killed compilation, and
a top-level fn whose body contained such a loop was silently dropped from
`resolve_fn_types` while call sites still referenced its `_as_value`
wrapper (undeclared identifier at the C compile). Both previously needed
source workarounds (grounding the type with an unreachable unit branch /
eta-expanding at the call site); the natural spellings now compile and
run. Two artificial rejections became working programs and their tests
were converted to positive assertions: an uninstantiated polymorphic
variant now emits a concrete int instance, and a lifted closure capturing
a tuple compiles and runs correctly (verified against the interpreter).
suite: 2230 passed / 0 failed._

---

## v0.1.68 — 2026-07-27

_C-backend maps get a hash index: `map_get` / `map_has` / `map_set` lookup
is now O(1) amortized instead of a linear scan. A concurrency probe (an
actor-owned "visited set" benchmark) showed the old cost dominating
everything else: 100k check-and-insert ops against a ~30k-entry map took
5.8 s (~58 µs/op, ~300x the 97-entry case) — the map, not the messaging,
was the bottleneck. The struct keeps its insertion-ordered keys/values
arrays (so `map_iter` order, `map_len`, and `map_delete`'s shift-remove
behavior are observably unchanged) and adds an open-addressing index of
array positions: linear probing, power-of-two capacity, rehash at 0.7
load, rebuilt after a delete (deletes shift positions and are rare).
Key hashing mirrors the structural key-equality emitter — splitmix64 for
scalars, FNV-1a for strings, recursive combination for tuple / record /
variant keys — so keys equal under `key_eq` always hash equal. Same
benchmark after: 10 ms (~580x). A 5k-entry grow/rehash/delete/iter
functional check and the full suite verify behavior parity; the
interpreter's map is untouched (correctness-first reference). suite:
2230 passed / 0 failed._

---

## v0.1.67 — 2026-07-18

_A caught `fail` is now silent on the C backend, found by the mere-ruby
dogfood's exception milestone. mere-ruby implements Ruby `begin/rescue` on
top of `fail` + `try_or`: a `raise` unwinds via `fail`, and `try_or`
catches it. But the C runtime's `__lang_fail_impl` printed `fail: <msg>` to
stderr unconditionally, before checking whether an active `try_or` would
catch the longjmp — so every rescued exception leaked a stderr line, even
though the program continued correctly. A caught failure is control flow,
not an error; it must be silent. The fix reorders the helper to longjmp
first and print only when the failure is genuinely uncaught (about to
abort). The LLVM backend and the interpreter were already silent-on-catch,
so this also removes a cross-backend divergence. suite: 2230 passed / 0
failed (1 new test)._

---

## v0.1.66 — 2026-07-18

_A C-backend duplicate-definition bug, found by the mere-ruby dogfood's
first method milestone. Adding `def` / method calls turned the
interpreter's evaluator into one large mutual-recursion group threading
two Maps (locals and methods) through eleven functions, and the C backend
refused to compile it: eighteen functions were each emitted twice, a
"redefinition" error. The cause was in per-instantiation
specialization. A polymorphic function's specialization list is grown,
across resolution passes, from one concrete arrow type per use site. When
a function is used from many sites, arrows that differ only in a region
type variable — which the mangled-name tag erases — accumulate as
distinct specs that all mangle to the SAME C symbol, so one fn_decl was
emitted per spec and the identical definitions collided. The two later
re-scan branches already deduped their arrows; the fix dedups the spec
list by its emitted C symbol at the single emission chokepoint, so
same-symbol specs collapse while genuinely distinct instantiations are
preserved. With the fix mere-ruby's evaluator compiles clean and runs
`def` / recursion / `return` byte-identical to `ruby`. suite: 2229 passed
/ 0 failed (1 new test)._

---

## v0.1.65 — 2026-07-18

_Shortest round-trip float formatting, forced by the newest dogfood. The
first program mere-ruby (a Ruby subset interpreter in pure Mere) could
not print was `puts 0.1 + 0.2`: Ruby prints `0.30000000000000004`, but
`str_of_float` formatted every float at 12 significant digits, printed
"0.3", and the original double was unrecoverable from the string —
`float_of_str (str_of_float x)` was not `x`. All four backends (the
interp's format_float, the C runtime helper, the LLVM IR helper, and the
Wasm JS hosts) now format at 12 digits first — every value that 12
digits already represented faithfully keeps its exact old rendering, so
nothing else changes — and widen toward 17 until the string parses back
to the same double, the same shortest-round-trip contract Ruby, JS, and
Python print with. Reading the four implementations side by side also
surfaced a real pre-existing divergence: the LLVM helper appended a bare
"." to whole-valued floats ("100.") where every other backend renders
".0" ("100.0"). Fixed in the same slice; the four backends were verified
byte-identical on a shared corpus. suite: 2228 passed / 0 failed (7 new
tests)._

---

## v0.1.64 — 2026-07-18

_A backend gap closed, found by the medit dogfood. `read_lines : str -> str
list` type-checked and ran under the interpreter, but the C backend had no
arm for it — so a compiled program that read a file into lines emitted an
undefined `mu_read_lines` and failed to link. The surface language promised
something the native target could not deliver, and the type checker could
not see it. The fix adds `__lang_read_lines`, a helper that matches the
interpreter's `input_line` semantics exactly: split on newlines, drop a
single trailing empty element when the file ends in '\n', and return the
empty list for an empty file — so "a\nb\n" and "a\nb" both give ["a"; "b"],
"" gives [], and "\n" gives [""]. Verified line-for-line against the
interpreter on those edge cases. suite: 2221 passed / 0 failed (2 new
tests)._

---

## v0.1.63 — 2026-07-18

_A native monotonic clock, so Mere can time itself. Every measurement in
this project so far shelled out to the `time` command; `now_ms` (a
self-contained native FFI over `clock_gettime(CLOCK_MONOTONIC)`, emitted
like the tcp_* / udp_* externs) returns milliseconds since an arbitrary
epoch, and that is enough to build a benchmark harness in pure Mere. The
dogfood is mbench: it runs a kernel enough times to span a target
wall-clock window, then reports iterations, total ms, and ns/iter,
threading a checksum through the loop so the optimizer cannot delete the
work. Writing it surfaced the universal benchmark trap first-hand — a
kernel that ignores the loop counter is loop-invariant and clang -O2
hoists it out (a plain summation was even strength-reduced to i + C,
reported as 0 ns/iter). The fix is the universal one: thread the counter
into every kernel's input. A quiet observation falls out — Mere-on-C
inherits clang's optimizer wholesale, for better (real kernels run fast)
and for worse (arithmetic-reducible kernels vanish). suite: 2219 passed /
0 failed (1 new test)._

---

## v0.1.62 — 2026-07-18

_A native UDP FFI, opened by a DNS resolver. mkv and mhttp used TCP; the
new dogfood, mdns, is the first datagram-socket program, and it needed a
capability that genuinely did not exist: udp_open / udp_send / udp_recv,
connected SOCK_DGRAM sockets that send and receive one datagram at a time
through the flat arena, reusing the protocol-agnostic tcp_close and
tcp_set_timeout. On top of them mdns builds a DNS query packet byte by
byte in the arena — a 12-byte header, length-prefixed labels for the
QNAME, QTYPE/QCLASS — sends one datagram to a resolver, and parses the
answer section, stepping past compressed names and reading each A
record's four IPv4 bytes. The same binary-packet construction and
length-prefixed parsing as a gzip block, but on the wire. Verified
against `dig +short` on several names (including this project's own
GitHub-Pages A set) and two resolvers. suite: 2218 passed / 0 failed
(2 new tests)._

---

## v0.1.61 — 2026-07-18

_An extern-in-closure capture bug, found the first time the client side of
the TCP FFI was driven. The dogfood is mhttp — an HTTP/1.1 client in pure
Mere over raw `tcp_connect` / `tcp_write` / `tcp_read` (mkv used the server
side; this is the first `tcp_connect`). Its `send_all` helper called
`tcp_write` from inside an inner recursive closure, and the C backend
refused to compile: the closure-lift analysis captured `tcp_write` as a
free variable and referenced it through the env as the namespaced
`mu_tcp_write`, while the extern itself is emitted raw. The cause: the
lift's "globals to exclude from capture" set held top-level fns and
builtins but not extern fns — so an extern used as a value inside a helper
was wrongly treated as a captured local. Externs are globals, referenced
directly in the generated C, so they now join that excluded set. With the
fix, mhttp parses status lines, case-insensitive headers, Content-Length
bodies, and chunked transfer-encoding, verified byte-for-byte against curl
(local server, both framings) and against a live server. suite: 2216
passed / 0 failed (2 new tests)._

---

## v0.1.60 — 2026-07-18

_int_of_str semantics pinned across all four backends, caught by a
Result-pipeline probe. The probe wrote an ordinary config pipeline —
parse three fields, validate, combine — and the same program printed
different errors on the interpreter and C: "not a number: abc" versus
"out of range: 0". The cause: the interpreter's int_of_str raised on
invalid input (so a try_or bridge caught it), while C was a bare atoll,
LLVM a bare atoi, and Wasm a hand-rolled stop-at-first-non-digit loop —
all three silently returning 0 or a partial prefix. The C emitter's own
comment admitted it: "Fail handling is omitted." The shared spec is now
strict decimal — optional surrounding whitespace, optional sign, one or
more digits, nothing else — and invalid input FAILS on every backend,
catchable by try_or: the interpreter validates before parsing (dropping
OCaml int_of_string's 0x/0o/0b acceptance, which no compiled backend
ever had), C gains a validating __lang_int_of_str over strtoll, Wasm's
WAT helper validates and calls $__lang_fail with an interned message,
and LLVM gains an IR helper over strtoll + endptr that calls
__lang_fail_impl. The probe's other measurements — the Result-chain
nesting tax and two phantom-type wrinkles — are design notes, not code
changes. suite: 2214 passed / 0 failed (6 new tests)._

---

## v0.1.59 — 2026-07-18

_Streaming file input, forced by a grep. The new dogfood is mgrep — a
grep-lite over the backtracking regex engine (examples/regex.mere, whose
probe also caught and fixed a real star-backtracking bug in the older
contrib/regex engine: `a*a` failed on "aa" because a single returned
end-position cannot give characters back to the rest of a sequence). The
measurements came in three acts. Act one: grepping a 94 MB file with
whole-file `read_file` + `str_split` peaked at 1.26 GB of RSS — thirteen
times the file — which forced the new capability: `file_open` /
`file_read_line` / `file_close`, an open read handle streaming one line
at a time, with EOF as option None rather than `read_line`'s ambiguous
"" sentinel (interp + C; Wasm/LLVM are pointed errors; File is Send but
not Sync). Act two: streaming alone made it WORSE — 2.4 GB — exposing
that the CPS matcher allocates its continuation closure on RSeq entry,
before the first character is tested: ~20 bytes of never-freed arena per
scanned byte. Act three: first-literal-byte and ^-anchor prefilters (what
real greps do with memchr) collapse the churn to match candidates — the
94 MB grep now runs in 100 MB and 1.8 s, output identical to grep -rn.
The residual 100 MB ≈ the file size is the cleanest number yet for the
known strings-lifetime hole: even perfectly streamed input accumulates
its line strings in the program-lifetime region. That, and the
closure-on-entry pattern, are the next region-reclamation forcing cases.
suite: 2208 passed / 0 failed (3 new tests)._

---

## v0.1.58 — 2026-07-18

_The ray tracer reaches the browser, and an annotation census closes a
question. The playground gains `/playground/raytrace.html`: the same ray
tracer as `examples/raytrace.mere`, compiled to Wasm, drawing to a canvas
through two new contrib/dom externs — `dom_canvas_fill_style` and
`dom_canvas_fill_rect`, the frontend FFI's first pixel-output surface (no
compiler change needed; the extern machinery took five-argument imports as
is). A headless harness that captures the canvas calls rebuilds the exact
PPM the native backends produce, and the page's status line shows the same
Adler checksum — cross-backend parity, visible on a page. Separately, a
census of the "annotate polymorphic params" wrinkle (T-4) measured what a
bidirectional-inference fix would actually buy: of 1,484 parameter
annotations across 255 examples, almost all are stylistic (plain int
params, vec_get results, and float literals all infer fine unannotated);
only two patterns genuinely require an annotation — a float flowing
through a polymorphic binding, and a record update on a polymorphic
parameter. Both have one-annotation workarounds, so the verdict is no
type-system surgery: the float case already had a pointed hint (v0.1.50),
and this release gives the record-update case its twin — the error now
names the workaround with an example. suite: 2205 passed / 0 failed (1 new
test)._

---

## v0.1.57 — 2026-07-18

_The Wasm backend had never actually assembled a float-heavy program with
functions, and a ray tracer proved it. The probe itself — three spheres, a
mirror bounce, hard shadows, all vec3 math on (float, float, float) tuples —
ran identically on the interpreter and C, but the Wasm build died in wat2wasm:
`local.set expected [i32] but got [f64]`. The cause: floats on Wasm are boxed
(an i32 pointer to a heap f64), and boxing needs a raw-f64 temp local. The
machinery to type those temps existed (`local_types`, Phase 34.3) and the
main-body emitter read it — but the three FUNCTION emitters (top-level, lifted,
closure adapter) ignored it and blanket-declared every extra local `i32`. So
float expressions at the top level worked, and any float temp inside a named
function produced invalid WAT. All three emitters now declare typed locals.
With that fixed, the ray tracer runs on all three executable backends with an
identical checksum and a byte-identical PPM (interp / C / Wasm). The checksum
had to be Adler-style rather than CRC-32 — 0xFFFFFFFF doesn't fit Wasm's 32-bit
int (the v0.1.41 pointed error, working as designed), and a logical shift
doesn't exist for it either. The boxing tax, measured: a 96×54 render allocates
26 MB from the never-freeing bump allocator (~5 KB per pixel); at 320×180 the
tax exceeds the fixed 64 MB linear memory and traps — the first concrete
forcing case for the deferred Wasm memory-growth work (E-2). `args` is also
unsupported on Wasm (pointed error), so the example writes its PPM
unconditionally instead of arg-gating it. examples/raytrace.mere. suite: 2204
passed / 0 failed (2 new tests)._

---

## v0.1.56 — 2026-07-17

_Full namespacing of user value/function names in the C backend — the robust
end of the reserved-name whack-a-mole. Six times a user name collided with the
C namespace (`index`, `remove`, `acct`, `dup`, `run`, `y0`), each patched by
adding to a hand-maintained reserved-word list or a missed sanitizer path. That
list is now gone: `c_safe_name` prefixes every user value/function identifier
with `mu_`, so nothing user-named can collide with a C keyword, a libc/POSIX
symbol, or a libm function ever again. Two properties make the uniform prefix
the real fix rather than a bigger list: additions to libm/POSIX can't
reintroduce the bug, and because the prefix is uniform, any emission path that
forgets to route a name through `c_safe_name` fails to compile for *every*
function (not just reserved-named ones), so the test suite surfaces such
bypasses immediately — that self-verifying property caught two latent
def/use mismatches during this change (pattern-variable binders and lifted-call
capture arguments), now fixed. Names emitted directly are unaffected: runtime
and generated symbols (`__lang_*`, `__anon_*`, `__lifted_*`, `closure_*`,
`mere_*`), FFI extern names, and the real `int main`. TYPE names (records and
variants) are a separate C namespace and stay un-prefixed via a new
`c_type_name`, leaving the recursive-variant machinery untouched. The
self-hosting byte-identical fixpoint is unaffected — it runs on the WAT backend,
which shares no naming with the C backend. suite: 2202 passed / 0 failed (~40
codegen-assertion needles updated to the `mu_` forms; behavior byte-identical
for programs that never shadowed a builtin). Both halves of the reserved-name
problem — Mere builtins (v0.1.54) and C symbols (this release) — are now closed._

---

## v0.1.55 — 2026-07-17

_A reserved-name parameter bug, in the one function-emission path the earlier
fix had missed. A date-arithmetic probe wrote `fn (y0: int) -> ...`, and `y0`
(with `y1`, `j0`, `j1`, `gamma`) is a libm Bessel function, already on the
reserved list. The interpreter ran it fine, but the C backend failed to
compile: the top-level curried function declared its parameter raw as `long
long y0`, while the body — which captures that parameter into the returned
closure's environment — referenced the sanitized `y0_`, an undeclared
identifier. v0.1.51 had fixed exactly this mismatch for `format_param` and the
closure adapter after the gzip probe hit it with `index`, but the plain
`emit_fn` path (a simple top-level curried function, not lifted) still inlined
the raw parameter name. It now goes through `format_param` like the others, so
the declaration and every reference agree. The probe itself — day-number
conversions, days-between, add-days, all as `(y, m, d)` tuples since there is
no date type — was otherwise new-bug-zero, matching a reference implementation
on weekdays, intervals, leap boundaries, and a thirty-thousand-day round-trip,
identically on both backends. suite: 2199 passed / 0 failed (2 new tests)._

---

## v0.1.54 — 2026-07-17

_User definitions now shadow builtins at the call site (the recurring
reserved-name pain, attacked at its other root). A Scheme-interpreter
probe named a function `run`; on the C backend that call compiled to
`__lang_run(...)` — the shell-exec builtin — because the builtin's
direct-call App-arm matched the name before the ordinary user-call path.
The interpreter had always shadowed correctly (a later `let` binding
wins), so only C was wrong. This is the same family as the `join` /
`is_digit` / `is_alpha` / `is_space` guards added case-by-case earlier:
a builtin App-arm should defer to a same-named user binding. Rather than
keep playing whack-a-mole, a single `user_shadows` helper (local /
captured / lifted-inner / top-level) now guards ~30 collision-prone
builtin arms (`run`, `spawn`, `even`, `odd`, `abs`, `show`, `fail`,
`exit`, `sqrt`, `sin`, `cos`, `tan`, `chr`, `ord`, `args`, `len`, `not`,
`fst`, `snd`, `sleep_ms`, `random_int`, `file_*`, `mkdir_p`, `list_dir`,
`read_line`, `read_key`, `tty_*`). The guard is strictly safe: it fires
only when the user actually bound that name, so programs that don't
shadow a builtin are byte-for-byte unaffected. This addresses the Mere
builtin half of the reserved-name problem; the C-keyword/POSIX half is
still handled by the `c_safe_name` suffix sanitizer, and full top-level
namespacing (which would subsume both) remains deferred. suite: 2197
passed / 0 failed (4 new tests)._

---

## v0.1.53 — 2026-07-17

_Lowercase record types, and one more reserved name (found by a
records-heavy ledger dogfood). Mere's convention is lowercase type names
with capitalized constructors — `type 'a list = Nil | Cons ...`. Record
types followed the same convention at declaration (`type addr = { ... }`
was accepted), but the record *literal* `addr { ... }` only parsed for
capitalized names, so a lowercase one fell through to a variable
followed by a block and failed with "expected ';' or '}' in block" — an
error far from its cause. A registered record name of any case followed
by `{` now parses as a record literal; nested updates like
`{ p | home = { p.home | city = ... } }` work throughout. Separately,
the ledger named a function `acct`, which collided with POSIX `acct(2)`
at C compile time; a batch of common short POSIX names (`acct`, `dup`,
`read`, `write`, `open`, `close`, `time`, `stat`, ...) join the
reserved-word sanitizer. That list is inherently incomplete — namespacing
all user top-level names is the robust fix, deferred as a larger
byte-stream change. `examples/ledger.mere` models double-entry
accounting with nested record updates. suite: 2193 passed / 0 failed
(3 new tests). One honest wrinkle unchanged: a record parameter that is
updated must be annotated, so the update site knows its type — the same
"annotate polymorphic params" rule as the numeric overload._

---

## v0.1.52 — 2026-07-17

_Inner functions get uncurried too (the real win the gzip probe was
pointing at). v0.1.27 gave curried TOP-LEVEL functions an uncurried
`__direct` twin so a saturated N-arg call skips the closure chain; inner
(nested) functions never got it, so a curried inner **recursive**
function compiled to a chain of anonymous closures — allocating a fresh
env from the never-freed region on every partial application AND every
recursive step. In a hot loop that is catastrophic: a 4-arg curried
inner rec fn called a million times allocated **769 MB** (the same work
with a single tuple arg: 1.4 MB), and gzip's `huff_decode` made
inflating 1 MB cost **484 MB**. Now curried inner-lifted functions
(≥ 2 params, concrete types) also get a `__direct` twin, and saturated
call sites — including the recursive self-call — use it. Measured: the
1M-iteration microbenchmark **769 MB → 1.46 MB (~530x)**; gzip inflate
of 1 MB **484 MB → 34 MB (~14x)**, still byte-identical with a verified
CRC-32. The single-param closure form stays for partial application, so
the change is additive and byte-stable (self-host emission unchanged).
suite: 2191 passed / 0 failed (3 new tests). This closes the memory
question the C-2 gzip dogfood opened — it was inner-fn currying, not the
bytes representation._

---

## v0.1.51 — 2026-07-17

_Three C-codegen bugs a gzip inflater flushed out. Writing a real
DEFLATE decompressor (stored + fixed + dynamic Huffman, ~300 lines)
exercised the closure-lifting and pattern-matching machinery harder
than any prior program, and each bug was an undeclared-identifier
compile error the interpreter never saw:_

1. _**Reserved-name params.** A parameter named after a C keyword
   (`index`) was declared raw but referenced via `c_safe_name` as
   `index_`. Fixed on both emission paths — lifted-fn params
   (`format_param`) and anonymous-closure adapters — where deeply
   curried inner functions land._
2. _**Cross-host capture confusion.** A plain local variable `p` was
   dropped from its function's captures because a DIFFERENT function
   had an inner recursive helper also named `p`: the "exclude
   inner-lifted fn names from captures" filter used a global,
   last-write-wins source-name map. Now resolved per-host, so a local
   and an unrelated inner fn sharing a name stay distinct._
3. _**Container-typed match fallthrough.** A `match` whose result type
   is a pointer container (`Vec`) emitted `(Vec___heap_int){0}` — an
   undeclared struct — for the non-exhaustive default arm, via
   `mono_variant_name` mangling. Pointer containers now zero to `NULL`._

_With all three fixed, the inflater compiles and runs with no
workarounds: it decompresses `gzip`-produced files (1 byte to 1 MB,
stored / fixed / dynamic) byte-identically with a verified CRC-32.
suite: 2188 passed / 0 failed (5 new regression tests)._

---

## v0.1.50 — 2026-07-17

_The classics quartet (matmul, Game of Life, Sudoku, bignum): four
textbook programs aimed at four suspected soft spots — nested
`Vec[Vec[float]]` construction, read-current/write-next generation
updates, mutate-and-undo backtracking over `vec_set`, and digit-vector
arithmetic past the fixed-width int. **All four ran correctly on interp
and C with zero new bugs**: the matrix product is exact, the glider
translates (+2,+2) in 8 generations, the 9x9 puzzle solves
(row0=534678912), and 30! comes out to all 33 digits (after 21!
demonstrates the wrap — identically on both backends). After 26
releases of probe-driven fixes, that's a measurement of the suite's
reach, and it's recorded as one. The single real pain was an ERROR
MESSAGE: when the numeric overload defaults to int through a
polymorphic helper (matmul's `mat_get`, whose element type is still a
type variable at inference time), the eventual "expected `float`, got
`int`" surfaces far from its cause. The unify hint now explains the
defaulting and both escapes (annotate a parameter / ascribe an
operand). All four programs join `examples/` (the Life one as `life_glider.mere` — `game_of_life.mere` already existed as the Phase 36 sugar showcase and stays untouched)._

---

## v0.1.49 — 2026-07-17

_A pub/sub broker, and the bug it flushed out. The dogfood set out to
force `select` (waiting on multiple channels at once) — and found it
**isn't needed**: a broker that must react to publishes, subscriptions,
and shutdown funnels everything through one command inbox as a `cmd`
variant (the actor pattern), so it never waits on two channels
simultaneously. The example also shows channels are first-class message
payloads — a `Sub` command carries a subscriber's `Channel[int]` through
the inbox. What the dogfood **did** force was a closure-lifting bug in
the C backend: a recursive `loop` that calls a sibling helper whose own
nested `rec go` closes over the helper's locals had those locals
(`hn`, `hv`) leak into `loop`'s capture set. The transitive-capture
fixpoint (which threads a callee's captures through its callers) added a
callee's captures without skipping names already bound inside the
caller, so `loop` was emitted as `__lifted_loop_N(bag, hn, hv, k)` —
referencing `hn`/`hv` that aren't in its scope ("use of undeclared
identifier"). Fixed by skipping any callee capture bound anywhere inside
the caller's body. `examples/pubsub.mere` runs a two-topic broker with
two subscribers on interp and C alike (`topic0=6 topic1=30`). E-1's
last piece, `select`, stays deferred — not from lack of trying, but
because the actor pattern subsumes it._

---

## v0.1.48 — 2026-07-17

_Timed receive for supervisors (the second half of the concurrency arc):
v0.1.47 let a worker pool shut down cleanly, but a **supervisor still
had no way to give up on a stuck worker** — `channel_recv` on the
results channel blocks forever if a job hangs. **`channel_recv_timeout :
Channel[a] -> int -> option[a]`** blocks up to N milliseconds for a
value and returns `None` on timeout (or once the channel is closed and
drained), so a collector records the timeout and moves on instead of
hanging the whole run. The C backend uses `pthread_cond_timedwait`
against an absolute `CLOCK_REALTIME` deadline; the reference interpreter
polls at 1 ms granularity (the stdlib has no timed condition wait).
interp + C; Wasm and LLVM reject it with a pointed compile error.
`examples/supervised_pool.mere` runs a pool where one job deliberately
hangs and the supervisor collects the other five with a 300 ms budget
(`results=5 timeouts=1`) on interp and C alike. Structured-concurrency
cancellation is already expressible via `channel_close`; the one
remaining E-1 piece is `select` over multiple channels, still waiting
for a forcing program (a genuine multi-source wait)._

---

## v0.1.47 — 2026-07-17

_Graceful shutdown for concurrency (found by a worker pool): the pool —
main pushes N jobs, W workers pull and process, main collects — hit two
walls at once. A worker's `channel_recv` loop blocks forever when the
jobs run out, so **there was no way to stop a worker and join it**; and
because the loop never returns, its type is bottom (`'a`), which the C
backend can't emit ("unsupported C codegen type: 'a"). Both are the
same missing primitive. **`channel_close : Channel[a] -> unit`** marks a
channel done, and **`channel_recv_opt : Channel[a] -> option[a]`**
blocks for a value but returns `None` once the channel is closed and
drained — so a worker loops `match channel_recv_opt jobs with None -> ()
| Some j -> ...; loop ()`, which terminates (returns unit, no longer
bottom) and can be joined. `channel_recv` and `channel_send` on a closed
channel now raise/abort instead of blocking or corrupting. interp + C
(the native worker-pool / server target); Wasm and LLVM reject the two
with a pointed compile error. `examples/worker_pool.mere` runs a
4-worker pool over 12 jobs and joins every worker cleanly. Closes the
structured-concurrency gap (E-1) that had been waiting for a forcing
program since the memory model landed._

---

## v0.1.46 — 2026-07-16

_(Follow-up, no version bump) `examples/base64.mere`: a composition
probe that confirms the day's three separately-shipped capabilities —
the bitwise builtins, `read_file_bytes`, and `write_file_bytes` —
compose in one program. RFC 4648 known-answer vectors pass, and passing
a file path round-trips arbitrary binary byte-identically
(`read_file_bytes → encode → decode → write_file_bytes`) on interp and
C. No new bug surfaced — the value is the integration check itself._

_Hex literals (a papercut two probes drove into the ground): both the
SHA-256 round constants and the East Asian Width range table had to be
written in decimal, because `0xFF` lexed as the int `0` followed by an
identifier `xFF` ("unbound variable: xFF"). `0xFF` / `0Xff` now lex as
ordinary ints — no separate type, same per-backend width — via
`int_of_string`; a bare `0x` with no hex digit still reads as `0` then
the identifier `x`. No octal / binary / digit-separator syntax (not yet
forced). The lexer change is one branch; the value is that the next
crypto or Unicode probe reads like the reference it's transcribed
from._

---

## v0.1.45 — 2026-07-16

_Columns, not codepoints (found by printing a table with Japanese
cells): v0.1.38's codepoint view was the right first step and the
wrong tool for alignment — `utf8_len` says 5 for こんにちは, a
terminal draws it in 10 columns, and a product table with CJK rows
comes out visibly ragged. **`utf8_width`** is the display width (East
Asian Width, wcwidth-lite: CJK / fullwidth / emoji = 2 columns,
combining marks = 0, halfwidth katakana = 1), and **`pad_right` /
`pad_left`** pad on it. All three are prelude functions in pure Mere —
UTF-8 decoded with plain div/mod arithmetic, the width table a dozen
range checks in decimal (the lexer has no hex literals, which is now a
recorded papercut) — so they landed on all four backends at once by
construction. `examples/aligned_table.mere` renders a mixed
ASCII / Japanese / emoji / halfwidth-katakana table with straight
borders on interp and C alike._

---

## v0.1.44 — 2026-07-16

_The picture that fixed the docs (found by a Mandelbrot renderer): the
probe went in expecting to measure the "no float infix" tax the docs
promised — and the docs were wrong in the language's favor. **`+ - * /`
and the comparisons had been numeric-overloaded for a while** on
interp, C, and Wasm; the reference still said prefix-only `f_add`
style, and a docs-faithful reader would write nine needless prefix
calls per formula. Three real gaps did surface around the stale entry,
all fixed: **unary minus was int-only** (`-2.5` was a type error;
negative float literals needed `f_neg`) — now overloaded like the
binary operators on all four backends (fneg / f64.neg); **the LLVM
backend emitted `add i32` on double operands** for float infix (invalid
IR, and `icmp` for float comparisons) — now the fadd family and
ordered fcmp; and **the write half of the binary path was missing** —
`write_file_bytes : str -> Vec[R, int] -> unit` joins v0.1.43's reader,
so PPM's raw P6 replaces the 2.6x-larger P3 ASCII escape.
`examples/mandelbrot.mere` renders 400x300 in infix math and writes P6
that is pixel-identical to the P3 version. One honest wrinkle stays:
the numeric overload resolves to float only on concretely-float
operands, so unannotated fn params default to int — float-heavy code
annotates its params. Docs corrected in both places._

---

## v0.1.43 — 2026-07-16

_Bytes get in the door (found by a 30-line CRC-32 tool): the algorithm
was trivial on the new bitwise builtins — the discovery was on the
input side. **`read_file` silently truncates binary data at the first
0x00 byte on the C backend** (NUL-terminated `char*`), while the
interpreter, whose strings carry NULs, read the same file correctly:
a 25-byte file read as 2 bytes natively and produced a confidently
wrong checksum. The str-is-bytes story was only true on interp.
**`read_file_bytes : str -> Vec[R, int]`** is the binary-safe path —
one int per byte, 0..255, the whole file, reusing the existing vec
machinery instead of introducing a bytes type (8 bytes per byte is the
honest cost until a program forces better). It gets the same
construction-time region binding as `vec_new` (without it, the region
tyvar stayed unresolved and functions taking the vec were silently
never emitted by the C backend — the probe hit that too). interp + C
for now; Wasm/LLVM reject it with a pointed compile error.
`examples/crc32.mere` verifies against zlib on both text and
NUL-bearing files; `read_file`'s docs now state the truncation
divergence plainly._

---

## v0.1.42 — 2026-07-16

_The real ALU (paying off the SHA-256 probe): **bitwise builtins on all
four backends** — `bit_and` / `bit_or` / `bit_xor` / `bit_not` /
`bit_shl` / `bit_shr`, on the backend's native int width, with
`bit_shr` as the arithmetic shift. They lower to the machine operation
everywhere: `&`-family operators on C, `i32.and`-family instructions on
Wasm, `and i32`-family on LLVM, `land`-family on the interpreter.
`examples/sha256.mere` dropped its div/mod fake ALU for them: one block
went from ~29 ms (interpreted, bit-loop emulation) to **6.7 µs native**
— about 4,300× — with all NIST vectors still passing on interp and C.
Cleanups the rewrite surfaced: `abs`/`min`/`max`/`clamp` still used C
`int` temporaries after v0.1.41 (silent truncation above 2^31, fixed);
`str_of_int` on a variable under a top-level let referenced an
undefined `show_int` on Wasm and LLVM (only `show` registered the
helper, fixed on both); the LLVM backend now rejects out-of-range int
literals at compile time like Wasm does — and the v0.1.41 changelog's
claim that LLVM was i64 is corrected there: **LLVM's int is i32**, and
widening it to 64-bit remains a deferred item with sha256 as the
forcing program._

---

## v0.1.41 — 2026-07-16

_One int, not four (found by writing SHA-256 in pure Mere): the probe
aimed at the missing bitwise story and instead hit something under it —
**the C backend's int was C `int`, 32 bits**, while the interpreter
tested 63-bit semantics and the docs never said which. SHA-256's round
constants (36 of them above 2^31) silently truncated and every digest
came out wrong with zero diagnostics; the minimal repro is
`2147483647 + 1`, which printed `-2147483648` natively and `2147483648`
under the interpreter. **The C backend's int is 64-bit (`long long`)
now**, with `LL`-suffixed literals so literal arithmetic doesn't wrap
at 32 bits either, `%lld` show/json formats, and `atoll`/`strtoll`
parsing. At the `extern fn` FFI boundary int deliberately stays C `int`
— the functions users declare are libc/POSIX symbols whose ABI type IS
the 32-bit int (declaring `getpid` as returning `long long` would read
undefined upper register bits on arm64). The **Wasm backend keeps its
i32 int but now says so**: an int literal outside `-2^31 .. 2^31-1` is
a compile-time error with a source location instead of an
`i32.const 4294967296` that only explodes later inside wat2wasm. The
SHA-256 probe passes all NIST test vectors on interp and C; docs state
each backend's width honestly. (This entry originally claimed LLVM was
already i64 — measuring said otherwise: **LLVM's int is i32**, so it
now gets the same out-of-range-literal compile error as Wasm, and the
i64 widening is a known deferred item. The probe also uncovered an
unrelated LLVM crash on this program, tracked separately.)_

---

## v0.1.40 — 2026-07-16

_Error-handling ergonomics probe (an 8-step fallible config-loader
written three ways): the verdict on the language was mostly good news —
the `?` / `?!` early-return sugar from Phase 36 already turns a
seven-level match pyramid into a flat sequence of bindings, and the
prelude's `result_and_then` family covers combinator style. The probe
found one genuine inconsistency: **the `?` / `?!` lets were the only
let form that rejected `;` as sugar for `in`** — `let x = e?!; rest`
was a parse error while every other `let x = e; rest` works. Fixed;
both forms now accept both separators._

---

## v0.1.39 — 2026-07-16

_Scale safety (found by sorting a million elements): **`list_sort_by` is
a stable merge sort now**, and **the prelude's list functions survive
million-element lists**. The insertion sort took ~2 s at 20k elements
natively and O(n²) beyond — a million-element `list_sort` now runs in
well under a second, still stable (ties keep input order; the merge is
tail-recursive via a reversed accumulator, and the split avoids
returning a tuple: a struct return compiles to an sret out-parameter in
C, which quietly defeats clang's sibling-call optimization — that one
cost an AddressSanitizer session to find). Ten more prelude functions
were rewritten with accumulators after the probe showed the naive
`Cons (f h, recurse)` shape overflowing the stack near a million
elements: `list_len`, `list_map`, `list_filter`-adjacent take/zip,
`list_append`, `list_concat`, `list_flat_map`, `range`, `list_max`,
`list_min`. The derive family (`==` on a million-element list) was
already safe. `list_sort_insert` remains for direct users._

---

## v0.1.38 — 2026-07-16

_Unicode (found by ten minutes of typing Japanese at the language):
**the codepoint view of strings**. A Mere `str` is — and stays — a byte
string: `str_len "こんにちは"` is 15, `substring` can cut a character in
half, and `str_rev` scrambles multibyte text; all documented rather than
changed (byte indexing is what the FFI, the wire protocols, and the
existing corpus rely on). What was missing was any way to work with
*text*: two new builtins on all four backends — `utf8_len : str -> int`
(codepoint count) and `utf8_chars : str -> str list` (split into
codepoints; invalid bytes count as single units, so they never loop or
throw) — plus prelude compositions `utf8_at`, `utf8_sub`, and
`utf8_rev`, written in plain Mere on top of `utf8_chars` so every
backend gets them for free. `utf8_rev "aあ😀b"` is `"b😀あa"` on interp,
C, Wasm, and LLVM alike — the first new builtin family to land on all
four backends at once (str_split's runtime scaffolding made LLVM
cheap)._

---

## v0.1.37 — 2026-07-15

_Memory model, ported to Wasm: **`region R { }` reclaims on the Wasm
backend** — the sound version of the save/restore that Phase 16.4
removed as broken. Three parts make it sound where the old attempt was
not: the block's result is **deep-copied out** (per-type `$__mcopy_<tag>`
fns, twice — once above the block's garbage, then down into the enclosing
range after the bump restores; the ranges cannot overlap); **escaping
stores are compile errors** (pushing a heap value into a container
created outside the block, `map_set`, `strbuf_push` on an outer buffer,
`channel_send`, `spawn`, and externs that register callbacks — a
container created *inside* the block is free to mutate, it dies with the
block); and **escaping closures/containers/borrows are rejected via the
result type**. Wasm needs no thread-locals or heap blocks: a mark saved
on the value stack and one scratch global do it._

_Measured on the live 2048 with a per-move region around the key
handler: the bump pointer stays at exactly 4,544 bytes across 30,000
moves — zero net allocation per move, zero traps. The same game
previously burned ~8.4 KB per move and died at ~7,700. The remaining
honest gap vs the C backend: no per-container storage (hence the
escaping-store errors instead of C's copy-on-store), recorded in
memory-model.md §3.5._

---

## v0.1.36 — 2026-07-15

_Library hygiene, applied across contrib: **importable libraries are
main-free now**. Five more libraries carried a demo main at the bottom
of the file (the pattern v0.1.35 fixed for contrib/test), so importing
them ran the demo — argparse, csv/writer, regex, regex/engine, and time.
Each demo moved to `examples/<name>_demo.mere` and runs standalone. The
self-host family (parser / typer / fmt / eval / codegen_wasm) keeps its
inline demos deliberately: those are programs whose demo output is the
cross-implementation test vector, not libraries._

---

## v0.1.35 — 2026-07-15

_Test-framework dogfood (three small things it surfaced):_

_**Generic assertions confirmed working.** `show` (like `==`, and like
`<` since v0.1.33) works through type variables — monomorphization plays
the dictionary — so contrib/test's `assert_eq` is genuinely generic: a
helper `fn s -> fn name -> fn x -> Test.assert_eq s name x x` asserts on
ints, tuples, nested pairs, and prints failing values with no
annotations. No language change was needed; the regression test pins it._

_**Library files must not carry a demo main.** contrib/test's demo lived
at the bottom of the library file, so every importer *ran* it (noise, an
intentional FAIL, and the demo's exit status). The demo moved to
`examples/test_framework_demo.mere`; the library is module-only now,
like contrib/xml._

_**`-I` now works when running a file.** The import search path flag was
honored by `-c` / `-l` / `-w` but silently dropped by the interpreter
path (`mere -I <dir> file.mere` failed to resolve imports that
`mere -c -I <dir>` accepted) — the run entry points now pass the search
paths through, closing another CLI asymmetry (cousin of v0.1.29's)._

---

## v0.1.34 — 2026-07-15

_Soundness (found by playing the live 2048 for ten thousand headless
moves): **`&&` and `||` now short-circuit on every backend**. The
interpreter and the C backend always short-circuited, but the Wasm
backend emitted strict `i32.and` / `i32.or` and LLVM emitted eager
`and i1` (behind a comment claiming the "MVP subset has no effects" —
long obsolete: a trapping right-hand side IS an effect). The
bounds-guard idiom `i < len && vec_get v i == x` therefore trapped on
Wasm only — in production, **97% of the live 2048's keypresses died
silently** in its stuck-detection (`r < 3 && bget b (i + 4) == v`),
invisible because the DOM glue catches and logs closure exceptions.
Both backends now lower `&&`/`||` to their If emission._

_The same probe measured the Wasm page-lifetime allocation model
(the memory-model work of v0.1.30–31 is C-only so far): the game burns
~8.4 KB of never-reclaimed bump per move and hits its 64 MB memory at
move ~7,700 — a determined player kills the tab in under an hour. That
number is now the forcing measurement for porting value reclamation to
the Wasm backend._

---

## v0.1.33 — 2026-07-15

_Polymorphic ordering: **`<` / `<=` / `>` / `>=` now work through type
variables**, closing the gap derive-ord (v0.1.11) left open. The design
is deliberately not a trait system: the scheme carries no constraint —
instead **monomorphization plays the dictionary's role**. Every compiled
instance of a polymorphic comparator compares at a concrete type, where
the existing derive machinery (`cmp_<tag>`) specializes; the interpreter
compares structurally at runtime. This is exactly how `==` has worked
through type variables all along — ordering simply joins it (the
historical "unresolved comparand defaults to int" rule is gone; programs
that used the default still typecheck, since instantiation covers them)._

_Consequences for free: the prelude's `list_sort`, `list_max`, and
`list_min` are now generic — `list_sort [(3, "c"), (1, "a")]` sorts
tuples with no annotations and no comparator; a hand-written
`fn a -> fn b -> a < b` instantiates at every use type (the generic
pairing-heap example drops its annotated comparator). Instances are
structural only — there is no way to override a type's ordering (the
derive family's philosophy), `_by` variants remain for explicit control,
and the parity scope is interp / C / Wasm, as with derive-ord._

---

## v0.1.32 — 2026-07-15

_Cleanup release (three small fixes plus doc sync):_

_**Top-level / local name collision (invalid C).** A local `let m = ...`
inside any function that shared its name with a globalized top-level
`let m` was emitted as an assignment to the file-scope global instead of
declaring a shadowing local — the prelude's `list_max` (local `m`) plus
a program-level `let m = map_new ()` produced C that didn't compile. The
global-assignment form now fires only for the exact top-level spine
bindings (matched by physical node identity), so same-named locals
declare and shadow correctly._

_**Tuple exhaustiveness false positive.** `match (h1, h2) with
(HE, _) | (_, HE) | (HN _, HN _)` is exhaustive, but no single arm is
total, so the checker warned "no wildcard arm for tuple" (found by the
generic pairing heap's merge). Tuple scrutinees whose components all
range over small finite spaces (bools / unit / registered variants) are
now checked by enumerating the product; a genuinely missing combination
is reported by example — `missing (Greenq, Greenq)` — instead of a
generic complaint._

_**mem_to_str leak.** It malloc'd and never freed; it now allocates in
the thread's current region, so per-request region blocks reclaim
byte-dialect strings too._

_Also: [memory-model.md](memory-model.md) gains §3.5 documenting the
implemented v0.1.30-31 reclamation semantics (current region, copy-out,
copy-on-store, per-message channel copies, backend notes)._

---

## v0.1.31 — 2026-07-15

_Memory model (stage 2 — the payoff): **`region R { }` now reclaims the
values its body allocates**. Value allocations (strings, cons cells,
variant nodes) target a thread-local **current region** instead of
hardcoding the never-freed default region; a region block makes itself
current for its body, deep-copies its result out into the enclosing
region (stage 1's `__mcopy` machinery), and releases. Closure envs and
container structs deliberately stay in the default region (they carry
identity), stores into containers are safe by stage 1's copy-on-store,
`channel_send` deep-copies the payload into a per-message region (freed
on `recv` after copying out into the receiver's current region — a
sender's scratch can die while the message is in flight), a container
cannot escape as a block result (the typer's region-escape check fires;
a codegen guard backs it up), and `try_or` restores the current region
when a `fail` longjmps past a block. Block regions are heap-acquired
with a one-deep per-thread cache, so a per-iteration block costs a
pointer swap and a bump reset — and, critically, no stack struct's
address escapes, which is what lets clang keep tail-calling. The spawn
trampoline frees a finished thread's cached region (`_Thread_local` has
no destructor — a spawn-per-connection server leaked ~1 MB per closed
connection without this)
(`show`/`to_json`/float-formatting helpers are `noinline` for the same
reason: their inlined `asprintf(&local)` silently broke sibling-call
optimization and deep loops overflowed the stack)._

_Measured: the idiomatic line-at-a-time counter — plain `read_line` +
`str_len` in a per-line region — now runs at **1.5 MB constant RSS over
8M lines** (246 MB before; `wc -l` needs 2.5 MB). A 100k-iteration loop
storing every 10,000th string into an outer map keeps exactly the stored
data. Long-running servers can finally reclaim per-request memory in the
string dialect, not just the byte dialect. Suite: 2093._

---

## v0.1.30 — 2026-07-15

_Memory model (stage 1 of the per-request-reclamation plan):
**copy-on-store — containers own their contents**. `map_set` deep-copies
the key and value into the map's own region, and `vec_push` / `vec_set`
copy the element, via per-type `__mcopy_<tag>` functions specialized the
same way the derive family (show / json / == / cmp) is: strings copy
their bytes, tuples / records / variants copy structurally (cons cells
and variant nodes re-allocate in the container's region), scalars and
closures pass through, and nested containers copy as pointers (mutable
identity and aliasing preserved — they own their own storage). Strings
are immutable, so the copies are semantically unobservable; the point is
lifetime: a stored value must not dangle when the storer's allocation
scope is later reclaimed. This is the prerequisite for scoped string
allocation (`region R { }` capturing str/cons allocations — the next
stage), which is what finally makes long-running servers' per-request
memory reclaimable. OwnedVec / StrBuf / Channel are deferred to that
stage. Today's cost: one copy per store; today's benefit: none visible —
by design._

---

## v0.1.29 — 2026-07-15

_Soundness (mkv dogfood P2): **sharing a mutable container across threads
is now a compile error**, and **the compile path runs the same safety
analyses as the run path**. Two fixes:_

_**Send/Sync classification.** Region-bound mutable containers (`Map` /
`Vec` / `StrBuf`) are now explicitly `!Send && !Sync` — their runtimes
are lock-free (linear-scan arrays / bump buffers), so a shared container
across `spawn` is a data race. Previously the classifier fell through to
"are all type args Send?", and the region-marker arg is a bare TyVar,
judged optimistically — so a shared `Map` compiled fine and lost ~2% of
concurrent writes in a real RESP-server stress test. `OwnedVec` stays
Send/!Sync (drop type: single owner, movable). The blessed pattern is
share-by-communicating: `Channel` remains Send+Sync, and the mkv actor
model compiles unchanged._

_**The `-c` / `-l` / `-w` paths now run the safety analyses.** The
compile entry ran type inference only — channel-element Send
obligations, borrow-conflict checking, and spawn-capture move analysis
were silently skipped, so `mere file.mere` rejected programs that
`mere -c file.mere` happily compiled (including capturing a region
borrow in a spawned thread). All three checks now run before codegen on
every backend._

---

## v0.1.28 — 2026-07-15

_Fix (generic-PQ dogfood, two monomorphization bugs): a **generic pairing
heap** (`type 'a heap = HEmpty | HNode of ('a * 'a heap list)` +
comparator closures) ran correctly on the interpreter but failed to
compile natively. Two independent root causes, both in the C backend's
monomorphization:_

_**B-P2 — body-only tuple shapes were never collected.** Tuple typedef
collection walked main's AST and fn signatures, but not fn bodies — so a
tuple that exists only as a body annotation (the `(h1, h2)` scrutinee of
a poly fn's match, concrete only inside a monomorphized instance's cloned
body) was referenced in the emitted C without ever being declared.
Bodies are now walked too; the concreteness guard still skips unresolved
polymorphic shapes._

_**B-P2b — no promotion to multi-instance.** A poly fn's usage sites
inside another poly fn's body only become scannable once that fn
resolves. `hp_pop` was seen at one type (from main), single-resolved by
unifying the original skeleton in place — destroying its polymorphism —
and the later-discovered second usage (at int, inside `drain`) was
emitted against the wrong instance's struct types. Every skeleton now
keeps a pristine clone taken before any unification; single-resolved fns'
bodies join the arrow-discovery scan; and a fn already resolved at one
type is promoted to multi-instance when a second type shows up._

_With both fixed, the generic heap and a Dijkstra built on it (new
`examples/generic_heap_dijkstra.mere`) run natively, byte-identical to
the interpreter. Suite: 2081._

---

## v0.1.27 — 2026-07-14

_Optimization (mlog dogfood P4, the big one): **saturated calls to curried
top-level fns compile to a direct N-ary C call**. Level-by-level
application allocated a closure env in the default region **per call**,
through the region lock — measured as O(iterations) permanent memory in
every multi-argument hot loop: a byte-at-a-time line counter held 2.1 GB
RSS over 8M lines. For each top-level `f = fn p1 -> .. -> fn pN -> body`
(N ≥ 2, concrete types) the backend now also emits `f__direct(p1, .., pN)`
and compiles exactly-saturated call sites straight to it — argument
temporaries pin the interpreter's left-to-right evaluation order, and
self-recursion becomes a C self tail call. Partial applications and
first-class uses keep the curried chain. The same line counter is now
**1.5 MB RSS, constant across input size** (below `wc -l`), and 300 MB of
input streams in 0.13 s. Constant-memory streaming is genuinely
expressible now; what still accumulates is the string dialect's per-line
`str` values (the open type-level lifetime question)._

---

## v0.1.26 — 2026-07-14

_Capability (mlog dogfood P1): **`read_line` on the C backend**. It was
interpreter-only — the sixth member of that family (print_err /
file_exists / print_no_nl / random_int / file_size) — so a native
streaming line processor could not be written at all (`read_stdin`
slurps the whole input by design). `__lang_read_line` reads one stdin
line without the trailing newline, `""` on EOF, matching the
interpreter. Found by measuring memory behaviour of line-at-a-time
processing for the constant-memory streaming question._

---

## v0.1.25 — 2026-07-14

_Fix (mkv dogfood, long-running processes): **regions grow instead of
aborting**. The region allocator was a single fixed-cap bump block
(default region: 4 MB) that aborted with `region OOM` on overflow — a
long-running server's per-command allocations (reply strings, cons
cells, tuples) exhausted it after a few thousand requests. A region is
now a chain of bump blocks: on overflow a geometrically larger block is
chained on. Blocks never move, so existing pointers stay valid, and
`region R { }` frees the whole chain at scope exit. Also hardened the
native byte arena: `mem_alloc` / `str_ptr` share one bump pointer across
spawned threads — it is now mutex-guarded and bounds-checked (it
previously raced and silently overflowed past the arena). Under a
sustained 80k-command concurrent load the RESP server now runs clean
where it previously aborted at ~8k. The honest remaining edge: growth is
not reclamation — per-request memory still accumulates for the process
lifetime (region-scoped strings need type-level lifetime tracking; see
the memory-model open questions)._

---

## v0.1.24 — 2026-07-14

_Capability (mkv dogfood, T4 wire-protocol server): native TCP **server**
primitives. `tcp_listen : int -> int` (socket + `SO_REUSEADDR` + bind +
listen, returns the listening fd) and `tcp_accept : int -> int` (blocking
accept, returns the client fd) join the existing `native_ffi_names`,
emitted as `static` impls against the same flat arena + POSIX sockets that
back `tcp_connect`/`tcp_read`/`tcp_write`. A Mere program can now be a TCP
server, not just a client — the server-side mirror of the pg/redis client
FFI. `SIGPIPE` is ignored so a client disconnecting mid-write drops the
connection rather than the whole process. This is the missing capability
behind a Redis-wire (RESP) key-value server; the earlier `http_serve` was
HTTP-specific and single-connection._

---

## v0.1.23 — 2026-07-14

_Fix (docs site): the Mere SSG (`contrib/site/build.mere`) parsed its
CLI args assuming `args()` still prepended the script path — the v0.1.12
`args()` consistency fix shifted that by one, so `input_dir` resolved to
the output dir and the site built **0 markdown pages** (tour.html /
tutorial.html etc. 404'd). Updated build.mere to the current `args()`
contract (first positional = input dir). A dogfood consumer that relied
on the old behaviour — exactly the interp/native `args()` mismatch N3 was
about, biting a Mere program this time._


**Fix: same-named inner functions no longer collide when lifted**
(2048 dogfood P3). Two inner fns sharing a source name within one
top-level function — e.g. a `let rec go` in each branch of an `if` —
both lifted to the top level, but each backend's inner-fn resolution map
is keyed by the source name, so the second `go` overwrote the first and
both call sites dispatched to the wrong one. **Cross-backend**: the C and
Wasm backends both mis-executed (silent wrong results); the interpreter
was correct. A new shared pre-pass (`Ast.uniquify_inner_fns_program`, run
next to the par_map lowering) α-renames on collision — the first use of a
name keeps it, a later reuse becomes `<name>_uq<N>` with its references
rewritten — fixing every backend in one place. Collision-free inner names
(the common case) are untouched, so nothing changes in ordinary code or
its pretty-printing.

2069 tests.

---

## v0.1.22 — 2026-07-14

**Wasm backend: `spawn` / `join` / `channel_*` now respect shadowing**
(2048 dogfood P2). A user binding named `spawn` — a game's tile spawner —
was dispatched to the *concurrency* builtin, silently turning the module
into a threaded one (shared-memory import + `$mere_spawn`), which the
plain browser host rejects. The same bug family the C backend fixed for
`join` in the mk dogfood (dd17b8a): the dispatch matched the name without
asking whether it was rebound. All five concurrency dispatches now check
the local scope / top-level fns / inner-lifted fns first, so a shadowed
name falls through to ordinary application while genuine `spawn` still
lowers to `$mere_spawn`.

Also in the frontend FFI (no compiler change): `contrib/dom` gained
`dom_on_key : (str -> unit) -> unit` — a global keydown listener passing
the key name to a Mere closure; the browser counterpart to native
`read_key`.

2067 tests.

---

## v0.1.21 — 2026-07-14

**`file_size` — a binary file's true byte length** (mwasm dogfood P1).
`read_file` is binary-safe (the buffer holds every byte and `char_at` /
`ord` index past NULs correctly, on interp *and* C native), but `str_len`
is `strlen` on the C backend and stops at the leading NUL — so a `.wasm`
(magic `\0asm`) reported length 0, and a binary walk couldn't bound its
loop. Added `file_size : str -> int` (stat's `st_size`, next to
`file_mtime`), on interp and C. With `(buffer, size)` carried explicitly,
the NUL-safe `char_at` / `ord` / `substring` make binary parsing
expressible — no dedicated bytes type needed yet. Driving app: `mwasm`, a
WASM binary inspector that reads the compiler's own output.

2065 tests.

---

## v0.1.20 — 2026-07-14

**`random_int` now works on the C backend** (mrog dogfood P3). The game's
wandering ghost picks a random direction each turn; `random_int` existed
only in the interpreter — the third interpreter-only builtin this dogfood
family has flushed out (after `print_err`, `file_exists`, `print_no_nl`).
Added `__lang_random_int` (seeded once from time^pid, uniform `[0, n)`,
fails on `n <= 0` like the interpreter). mrog M3 — ghost + game over —
now runs natively.

2064 tests.

---

## v0.1.19 — 2026-07-13

**`print_no_nl` now works on the C backend** (mrog dogfood P2). A TUI's
cursor-control sequences must be written without a newline and without
line buffering; `print_no_nl` existed only in the interpreter (the same
family as `print_err` / `file_exists` before it). Added the case
(`fputs(s, stdout); fflush(stdout)`). With it, mrog's full redraw loop —
ANSI clear+home, map with `@` overlay, hjkl movement, wall collision,
gold pickup — runs natively, byte-identical to the interpreter.

2063 tests.

---

## v0.1.18 — 2026-07-13

**Interactive terminal: `tty_raw` / `tty_restore` / `read_key`** (mrog
dogfood P1). Mere had only line-buffered input (`read_line` waits for
Enter, with echo), so an interactive TUI couldn't be expressed at all.
Three new builtins — interpreter (Unix termios) and C native
(`tcgetattr`/`tcsetattr`):

- `tty_raw : unit -> unit` — raw mode on stdin (no echo, no canonical
  buffering; ISIG stays on so Ctrl-C works). No-op when stdin isn't a tty,
  so piped tests behave.
- `tty_restore : unit -> unit` — put back the termios saved by the first
  `tty_raw`.
- `read_key : unit -> str` — blocking single-byte read; `""` on EOF.

ANSI *output* already worked (`chr 27 ++ "[2J"`), so with key input the
interactive read → update → redraw loop is now expressible. Driving app:
`mrog`, a tiny terminal roguelike.

2062 tests.

---

## v0.1.17 — 2026-07-13

**C backend: closures that call an inner-lifted fn now carry its captures**
(mk dogfood P5). An inline lambda passed to `par_map` that captures an
enclosing function's parameter gets inner-lifted, and its call sites inject
the captured variable as a leading argument. But when that call site sat
inside *another* closure — the `par_map` lowering's spawn lambda — the
spawn closure's env didn't include the injected variable, and the emitted C
referenced an undeclared identifier. The anonymous-closure capture
computation now unions in the captures of any inner-lifted fn the body
calls (one level suffices — lifted captures are already transitively closed
by the Phase 45 fixpoint). Found by `mk`'s parallel dependency groups
(`name [a b c]&: cmd`), which now build and run natively: three parallel
0.3s deps complete in ~0.38s, and a failing parallel dep propagates its
exit code.

2058 tests.

---

## v0.1.16 — 2026-07-13

**`run` is now truly parallel under `spawn` / `par_map`** (mk dogfood P4).
`run` was lowered to libc `system()` (and OCaml's `Sys.command`, which
wraps it) — and on macOS, concurrent `system()` calls serialize behind a
global lock, so `par_map (fn c -> run c) cmds` executed commands one at a
time: three parallel 0.3s sleeps took ~1.0s (interp) / ~1.6s (native).
Confirmed with a C probe (3 threads × `system("sleep 0.3")` = 1.01s;
`posix_spawn` = 0.32s). Reimplemented without `system()`:

- interp: `Unix.create_process "/bin/sh" ["sh";"-c";cmd]` + `waitpid`
- C native: `posix_spawn` + `waitpid` (`128 + signal` on signaled exit)

Three parallel 0.3s commands now take ~0.36s on both backends. Exit-code
propagation is unchanged. This is what a parallel task runner needs — the
`mk` dogfood's M5.

2057 tests.

---

## v0.1.15 — 2026-07-13

**`file_exists` now works on the C backend** (mk dogfood P3). Incremental
builds skip a task when its output exists and is newer than its inputs;
the "exists" check guards `file_mtime` (which raises on a missing path).
`file_mtime` was already on C, but `file_exists` was interpreter-only, so
the native build failed with `use of undeclared identifier 'file_exists'`.
Added the case (`stat(path, &st) == 0`, next to `__lang_file_mtime`). With
this, the `mk` task runner's incremental mode (`name (out: in1 in2): cmd`)
builds and runs natively — and its float mtime comparison rides the
v0.1.11 structural `>`.

2057 tests.

---

## v0.1.14 — 2026-07-13

**`print_err` now works on the C backend** (mk dogfood P2). The native
backend lowered `print` to `puts` but had no `print_err`, so a compiled CLI
couldn't write diagnostics to stderr — a native build using it failed with
`use of undeclared identifier 'print_err'`. Added the case
(`fprintf(stderr, "%s\n", …)`, mirroring `print` → `puts`); the docs'
3-backend claim for `print_err` is now actually true.

2056 tests.

---

## v0.1.13 — 2026-07-13

**`run` — Mere can start external programs.** A new `run : str -> int`
builtin executes a command line through the shell, inherits stdio, and
returns the exit code (interpreter via `Sys.command`; C native via
`system` + `WEXITSTATUS`). This is the capability the new `mk` task-runner
dogfood needed on day one — a whole class of tools (build systems, task
runners, anything that shells out) was previously inexpressible. Exit
codes propagate identically under interp and native.

2054 tests.

---

## v0.1.12 — 2026-07-13

Papercut batch — small dogfood findings paid back.

- **`args()` is now consistent between the interpreter and native binaries**
  (mstat N3). Both return only the program's own arguments, dropping the
  interpreter's script path / the binary name; the CLI entry point hands
  the post-script args to the `args()` builtin instead of it reading
  `Sys.argv[1..]`. An argument-driven CLI now behaves the same under
  `mere app.mere a b c` and the compiled `./app a b c`.
- **`str_of_float` renders whole-valued floats as `550.0`, not `550.`**
  (mstat N4). Fixed identically across interp / C / Wasm (and the `show`
  path), so all backends still agree and the output round-trips through
  `float_of_str`.

Deferred: bare `None` needing a type annotation is an inference matter,
not a papercut, and stays open.

2052 tests.

---

## v0.1.11 — 2026-07-13

**derive-ord: structural ordering, the sibling of structural equality.**
`< <= > >=` now work on any concrete type, not just `int` / `float` /
`str` — completing the compile-time-specialized "derive family"
(`show` / `to_json` / `of_json` / `==` / **`<`**).

- **Structural comparison** on tuples, records, lists, and variants, on
  **interp / C / Wasm**, all agreeing byte-for-byte. Lexicographic: tuples
  and records by declared field order, lists element-wise (shorter prefix
  is smaller), variants by **declaration order** then payload. Emitted as
  a `cmp_<tag>` function per type (the ordering sibling of `eq_<tag>`),
  and as `value_compare` in the interpreter, ordering variants by the same
  tag order the codegen assigns.
- `list_sort_by` with an annotated comparator now sorts a list of any
  structural type (`float` / record / tuple / …), closing the mstat N5
  finding's practical half.
- Backward compatible: an unresolved comparator type variable still
  defaults to `int`, so `fn a -> fn b -> a < b` and the bare `list_sort`
  stay `int`. A fully-polymorphic `list_sort` needs ad-hoc-polymorphism
  resolution and remains deferred (documented in the stdlib reference).

2052 tests.

---

## v0.1.10 — 2026-07-12

**Bootstrap fixpoint: Mere is truly self-hosting.** The Mere-in-Mere
compiler, compiled by itself and run as wasm, produces byte-identical
output to the reference — and that output runs correctly.

- **Self-host TCO (Stage 55f)**: the self-host codegen now emits
  `return_call_indirect` (guaranteed tail calls) for tail-position closure
  calls, tracked via a `tail` flag threaded through if / let / letrec /
  match. Deep tail recursion in self-compiled code stays stack-flat (a
  200000-deep counter completes; it overflowed before).
- **Three latent self-compilation bugs fixed (Stage 55g)** — found by
  trace-bisecting the self-compiled compiler until the bootstrap fixpoint
  held:
  1. Pattern checks: a `PConstr` payload sub-check ran eagerly even when
     the tag didn't match, dereferencing garbage (out-of-bounds traps).
     Payload checks now short-circuit.
  2. Var-vs-var string `==` lowers to pointer equality in the un-typed
     self-host codegen; `member_str` (and parser friends) switched to
     explicit `str_eq` — ghost closure captures are gone.
  3. The self-host lexer was missing the `\r` escape, corrupting the
     data-segment escaper's CR needle ("Err" emitted as "E\0d\0d").
- **Fixpoint regression test**: the suite now compiles a program with the
  interpreter-run compiler AND the self-compiled compiler and asserts the
  WAT outputs are byte-identical.
- Also: `let rec` written directly in the main expression now lifts on
  C + Wasm (mstat N6) instead of erroring.

2035 tests.

---

## v0.1.9 — 2026-07-12

Float operator overloading + libm name collisions — driven by the `mstat`
numeric-CLI dogfood.

- **Infix operators on float**: `+ - * /` and `< <= > >=` now work on
  `float`, not just `int` / `str`. Dispatched on the operand type at
  codegen (the same compile-time specialization as `show` / `to_json` /
  `eq`; no trait machinery). `Mod` stays int-only. All four backends'
  arithmetic/ordering covered. Also fixes a latent C bug where a
  whole-valued float literal emitted as `7` (via `%.17g`), making
  `7.0 / 2.0` integer division. *Caveat:* operands must be concretely
  float-typed — an unannotated `fn a -> fn b -> a < b` still defaults to
  int, so the default `list_sort` stays int (sort floats with an annotated
  comparator).
- **libm / POSIX name collisions**: a user fn named `fmin` / `fmax` / … now
  gets rehomed (`fmin_`) instead of clashing with `<math.h>` in the C
  backend (`conflicting types for 'fmin'`). Same treatment as `main`.

2033 tests.

---

## v0.1.8 — 2026-07-12

`of_json` / `of_json_opt` on the Wasm backend — backend parity.

- **Wasm `of_json` / `of_json_opt`**: ported the JSON deserializers to the
  Wasm backend, so all three shipping backends (interp / C / Wasm) have
  them — matching `to_json`'s coverage (LLVM excluded, it lacks `to_json`
  too). A WAT JSON-parser runtime builds a generic tree in linear memory;
  per-type `$__ojnode_<tag>` decoders build the typed value; strict
  `of_json` traps on error, `of_json_opt` returns `None`. This un-blocks
  the mere-blog dogfood's **wasm deploy path** (native-only since it
  adopted `of_json_opt` in v0.1.7).

2022 tests.

---

## v0.1.7 — 2026-07-11

`of_json` (derive-style JSON parsing) + docs push + ergonomics.

- **`of_json` / `of_json_opt`**: the deserialization mirror of `to_json`.
  `of_json : str -> 'a` parses JSON into a typed value, driven by the
  result type at the call site (an annotation `(of_json s : T)`) — JSON
  object → record fields by name, array → list / tuple, `null`/value →
  option, string / `{"Ctor":…}` → variant. Same compile-time
  specialization as `show` / `to_json`; interp + C (native) backends.
  `of_json_opt : str -> 'a option` is the non-crashing sibling (returns
  `None` on any parse / shape error) — safe for untrusted input like HTTP
  request bodies. Closed the mere-blog dogfood's request-parsing gap
  (PAIN B5): its handlers now decode into typed request records instead of
  plucking string fields, verified end-to-end on the native binary.
- **`option` is a transparent JSON nullable**: `to_json` now encodes
  `None` as `null` and `Some x` as `x` (was the tagged `{"Some":x}`) on all
  three backends, the idiomatic API encoding and symmetric with `of_json`.
- **Native `exit n`**: the C backend emits libc `exit()`, so a native CLI
  can set its process exit code (closed mq PAIN P1's last item).
- **Trailing commas**: allowed in list and tuple literals (`[1, 2, 3,]`,
  `(a, b,)`); records already allowed them.
- **Docs**: a one-page [Tour of Mere](tour.html) feature showcase, and the
  SSG's nav / index are now curated (Start here → tutorials → reference)
  with real page titles. Site live at merelang.org.

2019 tests.

---

## v0.1.6 — 2026-07-11

`to_json` (derive-style JSON) + native password-auth Postgres.

- **`to_json`**: a polymorphic builtin (`forall 'a. 'a -> str`, the JSON
  sibling of `show`) that serializes any value structurally — records
  become JSON objects (dropping the type name), lists/tuples arrays,
  nullary constructors `"Name"`, and payload constructors
  `{"Name": payload}`. Same compile-time-specialization approach as `show`
  (no trait machinery); works on interp / C / Wasm. Removes hand-written
  record→JSON writers (the mere-blog dogfood's PAIN B3).
- **Native SCRAM-SHA-256**: real SHA-256 / HMAC / PBKDF2 / base64 in the C
  runtime, so a native binary authenticates to a password Postgres over
  plaintext (TLS still pending). Verified against a scram-sha-256 server.
- **Native redis/mysql**: two arena↔hex helpers complete the byte-buffer
  FFI, so the whole `contrib/db` family — not just pg — compiles to native
  binaries. Verified driving a real redis.

1992 tests.

---

## v0.1.5 — 2026-07-10

**Native full-stack**: a web + Postgres app now compiles to a single
native binary. Driven by the mere-blog dogfood.

- **Native FFI runtime (C backend)**: the `tcp_*` / `mem_*` / `str_ptr`
  externs that `contrib/db` (pg / mysql / redis) speak — previously
  host-provided over the Wasm linear memory — get native implementations:
  a Wasm-style flat byte arena (32-bit offsets) plus POSIX sockets. So the
  pure-Mere wire-protocol drivers run in a native binary.
- **Native HTTP server**: `http_serve` runs a POSIX accept loop with the
  same handler contract as the Node host (`"METHOD URL"` + `http_set_*` /
  `http_get_header` / `http_current_body`).
- **Native crypto/util**: a real FIPS 180-4 `sha256_hex` and a
  `/dev/urandom`-backed `gen_request_id` (password hashing + session ids).
- Result: `mere -c app.mere | clang` yields a self-contained native web+DB
  server — no Node, no Wasm. (Postgres SSL / SCRAM auth on native are
  stubbed for now; use trust / plaintext.)
- **`let` main diagnostic**: a top-level `let main = …` now warns on the
  compile paths (not just the interpreter) with a message pointing at the
  entry-point convention, instead of surfacing a cryptic downstream
  `wat2wasm` clash.
- **Fix**: the C backend escaped `\n` / `\t` in string literals but not
  `\r`, so a carriage return broke the emitted C string (hit compiling
  pg's COPY unescape).

1978 tests.

---

## v0.1.4 — 2026-07-10

Driven by the mere-blog dogfood (a Rails-ish blog on `contrib/http` +
`contrib/db/pg`).

- **`let` constructor/record patterns on all backends**: `let Ctor (a, b)
  = e` and `let Rec { f = x } = e` now compile on the C, Wasm, and LLVM
  backends (previously only the interpreter accepted them; the compiled
  backends handled just `P_var` / tuple / wildcard). Each backend desugars
  the general case to a single-arm match.
- **`contrib/orm`**: a small, DB-agnostic typed layer — row decoders
  (`Orm.dec_int` / `dec_str` / `dec_bool` / `dec_str_opt` + `decode_rows`)
  over the `str option list` rows the `contrib/db` drivers return, plus
  matching JSON encoders (`Orm.enc_int` / `enc_str` / `enc_bool` /
  `enc_str_opt` / `enc_obj` / `enc_arr`). The ML answer to
  reflection-based ORMs.

1972 tests.

---

## v0.1.3 — 2026-07-10

Closes the last dogfood finding from the mq CLI.

- **String ordering**: `<`, `<=`, `>`, `>=` now work directly on `str`,
  comparing lexicographically (in addition to `int`). Previously the
  typer forced both operands to `int`, so `"a" < "b"` failed to
  typecheck and callers had to route through `str_compare`/`ord`.
  Works across all four backends (interp / C / Wasm / LLVM); the `int`
  default for unresolved operands is preserved, so existing code is
  unaffected.
- **contrib/json fix**: v0.1.2 claimed the serialiser had moved into
  `module Json`, but the functions were dropped rather than re-added, so
  the release actually shipped a parser-only `json.mere`. They are now
  restored inside the module — `Json.to_json_str (Json.parse_json s)`
  type-checks and round-trips as intended.

1961 tests.

---

## v0.1.2 — 2026-07-10

More dogfood-driven fixes (from the mq CLI).

- **`read_stdin`**: reads all of stdin as a `str` (interp + C backend), so
  CLIs can filter piped input (`echo … | mq '.query'`).
- **contrib/json**: the serialiser (`to_json_str` / `to_pretty_str`) moved
  into `module Json` and `writer.mere` was removed, so parser and writer
  share one `json` type — `to_pretty_str (parse_json s)` now composes.

1947 tests.

---

## v0.1.1 — 2026-07-10

Fixes surfaced by dogfooding two real apps on top of Mere: a realtime
collaborative editor (mere-notes, Wasm) and a native `jq`-like CLI (mq,
C backend). Mostly C-backend and contrib hardening.

- **Native CLI I/O**: the C backend implements `args()` (argv → str list),
  so a compiled Mere program can read its arguments.
- **C backend correctness**: respect shadowing of the `join` builtin (a
  local `join` no longer compiles to `pthread_join`); fix cross-host
  capture merging in inner-fn lifting (composing two modules that each
  have a same-named inner fn no longer corrupts captures); mask `chr`'s
  byte index so out-of-range input can't read past the char table.
- **C backend parity / ergonomics**: `str_eq` works as a function (not
  just the `==` operator); `str_of_int` pulls in the `show_int` helper;
  type annotations accept qualified module types (`Module.t`).
- **contrib hygiene**: `contrib/json` and `contrib/csv` no longer run
  self-test demos on import (library-clean, module-only).
- **Package system v0.2** (from the mere-notes dogfood): `mere install`
  (manifest + git/subdir deps + lockfile), a `[host]` entry + `mere serve`
  that vendor and run the Node host, and distribution via `release.yml` +
  `scripts/install.sh`.

1945 tests.

---

## v0.1.0 — 2026-07-09 (first tagged release)

First public tagged release of the Mere compiler. What it contains:

- **The language**: HM inference + let-polymorphism, region / view /
  `Trivial[R]` memory model with refined borrow modes, capability-passing
  effects, and feature-parity codegen to **C / LLVM IR / Wasm** alongside
  the tree-walking interpreter. 1936 tests.
- **Self-host**: lexer / parser / typer / eval / fmt / codegen are written
  in Mere and compile themselves through the Wasm pipeline.
- **Concurrency**: `spawn` / `channel` / `join` + `par_map` on all four
  backends, with a `Send` / `Sync` type discipline.
- **Package system v0.2**: `mere install` (manifest + git deps with
  monorepo `subdir`, transitive resolution, `mere.lock`) and a `[host]`
  entry + `mere serve` that vendor and run the Node runtime host — so an
  app builds and runs from just an installed `mere`, no source tree.
- **Distribution**: `release.yml` builds prebuilt binaries for macOS
  (arm64 / x86_64) + Linux (x86_64) on each `v*` tag; `scripts/install.sh`
  installs one without an OCaml toolchain.

Work since the entries below (2026-07-07…09): self-host frontier
completion (module-import inlining fix; while / brace-block / vec / map
builtins), the concurrency stack, and the package-system + distribution
tooling above.

---

## 2026-07-06 — Tutorial: implement type inference in Mere (roadmap step 4, third of three — series complete)

Third and final tutorial in the initial series (direction paper's
educational thread). Builds the unification engine at the heart of
Hindley-Milner over a tiny lambda calculus + `let`.

- `docs/tutorial-type-inference.md` — auto-published. Builds
  bottom-up: the `expr` / `ty` ASTs (with `TVar` unification
  variables), fresh-var supply (single-slot vec), the substitution +
  `apply`, the occurs check, `unify` (tuple-match core), and `infer`
  (6 cases). Then the honest **HM leap** section: explains why the
  monomorphic `let` here rejects `let id = fn x -> x in id id`, and
  what let-generalization / instantiation add — pointing to the real
  `contrib/typer` (which runs in the browser playground).
- `examples/tutorial_type_infer.mere` — the worked example. Verified
  end-to-end: `fn x -> x : t0 -> t0`, `fn f -> fn x -> f x :
  (t6 -> t7) -> t6 -> t7` (arrow domain parenthesized), `(fn x -> x) 5
  : int`, `let id = fn x -> x in id true : bool`, `1 2 : TYPE ERROR`
  (int isn't a function), `id id : TYPE ERROR` (occurs check).

The tutorial series now covers all three planned tracks:
1. REST API (`contrib/http` — routing / path params / CRUD)
2. Redis client (raw TCP externs — the RESP protocol)
3. Type inference (the HM unification engine — self-host compiler
   internals)

Together they span the three positioning directions: Wasm-first
backend (1), the network/systems layer (2), and the educational
PL-implementation angle (3).

## 2026-07-06 — Tutorial: build a Redis client in Mere (roadmap step 4, second of three)

Second educational tutorial. Builds a minimal Redis client from the
raw TCP + memory externs to teach the RESP wire protocol — the layer
`contrib/db/redis` sits on top of.

- `docs/tutorial-redis-client.md` — auto-published (nav + sitemap +
  search). Covers RESP in a table (`+` simple / `-` error / `:` int
  / `$` bulk / `*` array), then builds bottom-up: the `tcp_*` +
  `mem_*` externs, the reply variant, byte / line / exact-count
  readers, the first-byte dispatch parser, and command encoding
  (`*N\r\n$len\r\narg\r\n`). Ends pointing at the full
  `contrib/db/redis` (RESP3, pipelining, TLS, pub/sub) + queue /
  stream / lock modules + the pg driver (same `mem_*` pattern).
- `examples/tutorial_redis_client.mere` — the worked example.
  Verified end-to-end against `redis:7`: PING → `+PONG`, SET →
  `+OK`, GET → bulk `"hello mere"`, GET missing → nil, DEL → `:1`
  — one reply type exercised per command.

Teaching point emphasized: bulk strings use a length prefix (not
line scanning) because payloads can contain `\r\n` / NUL — so
`read_bulk` reads an exact byte count via `read_exact`, unlike the
CRLF `read_line` used for status / length lines.

Note: `tcp_*` externs need the Node runner's sync TCP worker; they
are NOT available on Cloudflare Workers (no raw sockets) — called
out in the tutorial.

## 2026-07-06 — Tutorial: build a REST API in Mere (roadmap step 4, first of three)

First educational tutorial (direction paper's step 4). A guided
walkthrough that builds a minimal notes REST API on the
`contrib/http` stack — create / list / fetch / delete over JSON,
storage in-memory (no DB to set up).

- `docs/tutorial-rest-api.md` — the tutorial, auto-published to the
  docs site (nav + sitemap + search picked it up automatically).
  Builds the program up in 5 steps (route → store+create → list →
  path-param fetch → delete), each snippet grounded in real code,
  then points to next steps (Postgres persistence, ETag concurrency
  via `http_rest_notes`, auth, middleware).
- `examples/tutorial_notes_api.mere` — the complete worked example
  the tutorial references. Verified end-to-end: create → 201,
  list → JSON array, fetch → full note, missing → 404, delete →
  `{"deleted":true}`, list-after-delete correctly skips the removed
  note (the list walk gates on `map_has`, so a deleted id left in
  the order vector drops out silently).

Teaching points surfaced in the tutorial: the `\{` escape for JSON
object literals (bare `{` starts string interpolation), top-level
`let rec` for recursive helpers (Wasm backend disallows `let rec`
nested in a fn body), and `route_pattern` `:id` captures working
across GET and DELETE.

README gains a pointer under Documentation.

## 2026-07-05 — Cloudflare Worker: package registry v0.1 (JSON API)

Second CF Worker sample from the direction paper. Read-only JSON API
over a static-ish bundled package list — the foundation for
`mere install` speaking a normalized endpoint instead of hitting
GitHub directly.

`examples/cloudflare-worker-registry/`:

- `main.mere` — routes + response builders + naive JSON scan/escape
- `worker.js` — CF entry, exposes bundled `packages.json` to Mere via
  a `cf_registry_data ()` extern
- `packages.json` — v0.1's source of truth (3 sample entries:
  mere-http / mere-db / mere-json). To add a package: edit + rebuild
- `wrangler.toml`, `build.sh`, `local_test.js`, `README.md`

Endpoints:

- `GET /` landing HTML
- `GET /pkg` whole registry
- `GET /pkg/:name` one package's metadata
- `GET /pkg/:name/latest` latest version
- `GET /pkg/:name/:version` specific version

Verified via `node local_test.js` — **21 assertions across 8 request
scenarios**, all pass:
- Landing 200 + HTML
- `/pkg` lists all 3 packages
- Package metadata has owner / latest / versions
- `/pkg/mere-http/latest` returns injected `{name, version, tarball, ...}`
- Specific version endpoint works
- Unknown package → 404
- Unknown version → 404
- POST → 404 (only GET supported)

Two landmines fixed during shipping:
- **Balanced-brace parser bug**: earlier `while` loop set `i = n` to
  break out but then the "start >= n → empty" check false-negatived
  every extraction. Restructured with an explicit `done` flag.
- **Unescaped `\n` in 404 body**: `resp_not_found` splices `msg` into
  response body JSON without escaping. Added a `json_esc` pass.

Wasm size: 11 KB. v0.2 roadmap in the README (GitHub tag fetching,
KV cache, publish endpoint, `mere install` CLI).

## 2026-07-05 — Cloudflare Worker: playground snippet share (KV-backed)

Turned the CF Worker template from "hello, method+path echoed" into
a real sample that motivates Workers over static hosting: a
playground-snippet share service backed by Cloudflare KV.

Endpoints:

- `GET /` landing HTML
- `POST /share` raw code → 8-hex id + `KV.put`, returns `{id, url}`
- `GET /s/:id` returns stored snippet, 404 if unknown

The async KV binding on CF is bridged to sync Mere externs via two
conventions:

- **Pre-fetch** (read path): worker awaits `KV.get(id)` BEFORE
  calling Mere; the value lives in a module-scoped
  `currentKvLookup` and Mere reads it via `cf_kv_lookup ()`.
- **Outbox** (write path): Mere emits `kv_put:{key,value}` in the
  response JSON; worker honours it AFTER the handler returns via
  `KV.put(key, value)`.

Body handling uses the same "extern-not-JSON" convention: JS stashes
the raw request body in a module scratch, Mere reads it via
`cf_body ()`. This sidesteps a JSON-in-JSON double-escape bug where
`\n` inside stored snippets turned into `\\n` after round-trip.

Local smoke test (`local_test.js`) verifies six assertions with an
in-memory KV mock:

- Landing page 200 + text/html
- `POST /share` returns 201 + JSON id/url, KV was written
- `GET /s/:id` returns 200 with the ORIGINAL code (newlines
  preserved byte-for-byte — regression for the double-escape bug)
- Unknown id → 404
- Empty body → 400
- Unknown route → 404

Wasm size: 5.7 KB → **8.1 KB** (added routing + JSON escaper + KV
outbox construction).

## 2026-07-05 — Cloudflare Worker template (roadmap step 2)

Step 2 of the direction-paper roadmap. A minimal, self-contained
template that runs a Mere program as a Cloudflare Worker — 5.7 KB
compiled wasm, no npm runtime deps, V8-isolate compatible.

`examples/cloudflare-worker/`:

- `main.mere` — 30-line handler. Registers a request handler via a
  new `cf_on_fetch: (str -> str) -> unit` extern. Handler receives
  JSON-encoded request, returns JSON-encoded response.
- `worker.js` — CF Worker entry (ES module). Provides `cf_on_fetch`
  + the standard prelude stubs, marshals `Request` ↔ JSON ↔ Mere
  closure via the existing `__lang_bump` + `__indirect_function_table`
  machinery.
- `wrangler.toml` — CF Worker deploy config.
- `build.sh` — `mere -w main.mere → main.wat → main.wasm`.
- `local_test.js` — Node 22-based smoke test using native
  `Request`/`Response` (no wrangler/miniflare required for
  verification).
- `README.md` — layout, build/deploy commands, request/response
  protocol, and an explicit "what doesn't work on CF" section (no
  TCP / subprocess / fs — those are Node-runtime-specific externs).

Verified locally via `node local_test.js` — three requests round-trip:
- `GET /` → `hello from Mere on Cloudflare — GET /`
- `GET /hello?name=world` → same shape, path echoed
- `POST /submit` → method + path echoed

Actual `wrangler deploy` requires a Cloudflare account and is left
to the operator (`README.md` documents the commands).

Deliberate non-goals for this template: KV / R2 / D1 bindings,
Durable Objects, auto-rebuild watcher. All addable incrementally.

## 2026-07-05 — package system v0.1: `.mere_modules/` walk-up resolution

First step of the direction-paper roadmap. Extends the import
resolver in `lib/parser.ml` with Node.js-style `node_modules` walk-
up semantics — a project puts vendored packages under
`.mere_modules/`, and any file in the tree can `import "pkg/module.mere"`
without relative `../` navigation or `-I` flags.

Resolution order (relative paths only; absolute paths still resolve
literally):

1. `<importer_dir>/<path>` — historical behaviour
2. `<nearest .mere_modules up>/<path>` — new (Node-style walk-up)
3. `-I` dirs + `MERE_PATH` env — historical, order preserved

Deliberate v0.1 non-goals (documented in `docs/packages.md`):

- No `mere.toml` manifest yet (track deps by git URL / commit)
- No `mere install` command (git clone / submodule / tarball drop)
- No central registry (planned for v0.3+, design in internal notes)
- No version resolution (walk-up first-match-wins)

Vendoring workflow — three equivalent options, all documented:

    git clone https://github.com/<owner>/<pkg> .mere_modules/<pkg>
    # or
    git submodule add https://github.com/<owner>/<pkg> .mere_modules/<pkg>
    # or
    curl -L https://example.com/<pkg>.tar.gz | tar xz -C .mere_modules/

New docs page `docs/packages.md` with layout, semantics, precedence,
and a self-contained demo pointer. Demo `examples/pkg_demo/`:
- `main.mere` — 3 lines, `import "hello/greet.mere"; print (greet "world")`
- `.mere_modules/hello/greet.mere` — one-liner greeter package
- End-to-end verified: `mere -w examples/pkg_demo/main.mere` →
  `hello, world!`

Three new regression tests in `test/test_basic.ml`:
- Single-level walk-up (`.mere_modules/` alongside entry file)
- Deep walk-up (entry file in `app/handlers/`, modules dir above)
- Cross-package imports find the same `.mere_modules/` root

All 7 spot-checked existing demos (`http_blog`, `http_admin_dash`,
`http_router_demo`, `http_ws_chat`, `db_redis_pubsub`,
`subprocess_demo`, `gh_stars`) recompile unchanged. Test suite:
1846 → 1849.

## 2026-07-05 — `contrib/db/redis_ratelimit`: distributed fixed-window limiter

Multi-instance version of `contrib/http/ratelimit` (which is
in-process only — two Mere HTTP servers would each keep their own
counter, so a caller can rotate through instances to bypass). This
version puts the bucket counter in Redis so N instances share one
budget per key.

Standard `INCR` + `EXPIRE` pattern:

- `redis_rate_over_limit fd key window_sec max` → bool
  Increments the counter for the current window and returns
  `true` if `count > max`. Attaches TTL on the first hit of a
  bucket via `EXPIRE`; subsequent hits are single-`INCR` calls.
  Fail-open on network error (returns `false`).
- `redis_rate_count fd key window_sec` → int
  Peek without incrementing. Useful for
  `X-RateLimit-Remaining` headers.

Bucket key layout: `<key>:<epoch/window>` — all instances at the
same wall-clock second share the counter. Not sliding-window (a
burst right at the boundary can spike to 2 x max); document for
callers who need bursty tolerance.

Demo `examples/db_redis_ratelimit.mere` — 3-per-2-sec policy:
attempts 1-3 return `ok`, 4-5 return `BLOCKED`, then a `sleep_ms
2200` triggers a window roll and the next attempt returns `ok`.

## 2026-07-05 — `contrib/os/parallel_map`: N shell commands in parallel

Sits on top of `contrib/os/subprocess`. No new externs. Uses shell
backgrounding (`&`) + `wait` + tmpfiles to run N children
concurrently under the OS scheduler, then reads their stdouts back
in **index order** (not completion order).

The "cheap dogfood" step between the sync `subprocess_run` primitive
and a native `worker_spawn` / `worker_await` pair that a future
worker_threads shipping will bring.

    parallel_map : str list -> str list

Verified end-to-end:
- 4 x `sleep 1 && echo <label>` → **1135 ms wallclock** (~max of
  individual times, not sum of 4000), results `[A; B; C; D]` in
  submitted order
- Mixed timings (0 / 2 / 1 sec) → **2099 ms wallclock**, results
  `[instant; two-sec; one-sec]` — the slowest child at index 1
  dictates wallclock; ordering follows input order, not completion

Not suitable for streaming (all children must exit before return),
very short-lived children (fork overhead dominates), or output
containing the fixed sentinel `__MERE_PMAP_SEP_9c3d4f7a__`.
Documented in the module.

## 2026-07-05 — `contrib/os/subprocess`: sync shell-out (Q-012 Path A)

First shipping toward the concurrency-primitive design (see design
notes in the project's internal notes). Path A of the plan — the
"no language change, immediate utility" step before a proper
`spawn` / `channel` primitive.

Three externs backed by Node's `child_process.spawnSync`:

- `subprocess_run cmd stdin -> str` — shell-execute, feed stdin,
  return stdout. Timeout 30 s, buffer cap 16 MiB per stream.
- `subprocess_status ()` -> int — exit code of the last run
  (0 = ok, nonzero = child, -1 = signal / timeout).
- `subprocess_stderr ()` -> str — stderr of the last run.

Blocking by design. `subprocess_run` holds the whole Wasm frame
until the child exits — a Mere HTTP server MUST NOT call it inside
a request handler.

Deliberate scope: no async / parallel-collect primitive. For
parallelism today, users can shell-background inside one call:

    subprocess_run
      "sh -c '(child1 > /tmp/r1) & (child2 > /tmp/r2) & wait; " ++
      "cat /tmp/r1; echo ---; cat /tmp/r2'"
      ""

The two children run concurrently under the OS scheduler; only
collection is serial. A proper `worker_spawn` / `worker_await` pair
is scheduled for Q-012 step 3 (post `worker_threads` restructure).

Demo `examples/subprocess_demo.mere` verifies all four flows:

- `date -u` → status 0, timestamp captured
- text piped into `wc -w` → 5
- `false` → status 1, stderr captured
- two `sleep 1` in parallel via shell `&` → **1055 ms wallclock**
  (not 2000+ ms — real OS-level parallelism)

Wired into both `run_wasm.js` and `run_http_server.js` via the
same factory pattern as `http_fetch_env`. 1846 tests pass.

## 2026-07-05 — `contrib/http/websocket`: RFC 6455 hub

WebSocket support in the standard shape:

- Handshake — `GET /ws/<channel>` with `Upgrade: websocket` and
  `Sec-WebSocket-Key` → 101 Switching Protocols with the standard
  `Sec-WebSocket-Accept: base64(sha1(key + magic))` computation.
- Text frame codec — encode server → client (unmasked), decode
  client → server (masked with per-frame XOR key). Both length
  forms (7-bit / 16-bit / 64-bit) supported.
- Channel pool — `/ws/<channel>` sockets go into a per-channel Set;
  `ws_broadcast` writes to every socket, auto-relay writes to every
  socket EXCEPT the sender.
- Close + ping — client close → echo close + destroy socket. Ping
  → reply pong with same payload.

Public API (`contrib/http/websocket.mere`):

- `ws_broadcast channel payload -> unit` — server → all clients.
- `ws_client_count channel -> int` — for a "0 listeners → skip
  work" fast-path.

**Deliberate design choice**: individual client frames are NOT
delivered to Mere. The glue auto-relays them to peers on the same
channel (hub pattern), covering chat / cursor-share / collaborative-
edit demos without needing an in-Wasm callback per frame. Per-frame
Mere handlers would require a callback-into-Wasm design and stay
deferred.

Not supported (documented):
- Binary opcodes (0x2) — silently dropped
- Fragmentation (FIN=0 continuation) — every frame treated as full
- Payloads > 2^32 bytes (unrealistic for browser peers)

Demo `examples/http_ws_chat.mere` — auto-relay chat + admin
`POST /announce` → `ws_broadcast`. Verified with a native
`WebSocket` probe on Node 22:
- A sends "hello from A" → B receives it, A does NOT (hub excludes
  sender)
- `POST /announce {"msg":"hello everyone"}` → `{"delivered_to":2}`,
  both A and B receive `[admin] hello everyone`

All 5 spot-checked existing HTTP demos (router / blog / chat /
pubsub_chat / admin_dash) recompile and serve as before — the
`Upgrade` hook is a new event handler on the same server, so
non-upgrade requests are unaffected.

1846-test OCaml suite passes.

## 2026-07-05 — `examples/http_admin_dash`: integration dogfood

One small admin console exercises six of the modules shipped over
the last day in a single mere file (~200 lines):

- `contrib/http/router`     — `route_prefix "/admin"` + exact routes
- `contrib/http/session`    — cookie sessions (random 16-hex ids)
- `contrib/http/csrf`       — synchronizer-token on the "run job" POST
- `contrib/http/basic_auth` — Prometheus scrape gate on `/metrics`
- `contrib/http/metrics`    — `/metrics` + `with_metrics` middleware
- `contrib/http/cache`      — `cache_no_store` on admin pages
- `contrib/db/redis_lock`   — "only one instance runs the job" mutex

Feature: press the dashboard's "run job" button. The server acquires
a Redis lock, sleeps 500 ms (simulated work), releases. A second
instance clicking during the sleep window hits `redis_lock_acquire`
→ `None` and returns 409 `"contended"`.

Verified multi-instance end-to-end (two processes on `:8080` +
`:8081` sharing one Redis at :15650):

- Login flow: admin/adminpw → session cookie → dashboard 200 with
  a CSRF token in the form's hidden input.
- Concurrent kick: instance A returns 200 `"job ran successfully
  (held lock for 500 ms)"`, instance B returns 409 `"contended:
  another instance is running the job"`.
- CSRF check: POST without the token → 403.
- `/metrics`: without Basic Auth → 401, `-u scraper:s3cret` → 200
  with `jobs_run_total 1` in the scrape body.

The demo also documents the multi-instance run recipe in the
header comments so users can reproduce the race locally with two
`PORT=…` invocations against the same Redis.

## 2026-07-05 — `contrib/db/redis_lock`: distributed mutex + `gen_request_id` shared

Standard `SET key <token> NX PX <ttl_ms>` acquire with compare-and-
delete release via Lua EVAL. Enough for "at most one worker across N
processes should be running this job right now"; not enough for
critical-section-with-consequences workloads (RedLock, CP consensus).

- `redis_lock_acquire fd key ttl_ms  -> str option`
  Some fencing token on success, None on contention.
- `redis_lock_release fd key token   -> bool`
  Compare-and-delete Lua: only deletes if the key's current value
  matches the caller's token. Prevents "A's TTL expires, B
  acquires, A's stale Release blows away B's lock" bugs.

Also hoisted `gen_request_id` (16-hex random) from
`run_http_server.js` into `scripts/pg_env.js` so CLI Mere programs
under `run_wasm.js` can use it too — the lock's fencing tokens
were the immediate trigger, but any test harness minting session
ids or correlation ids benefits. All 7 existing consumers
recompile unchanged.

Demo `examples/db_redis_lock.mere` walks the six-step race:
- A acquires (fresh token)
- B tries → None (contention)
- A releases → true (CAS matches)
- C acquires (fresh token)
- Impostor tries release with wrong token → false, lock intact
- E tries → None (C still holds), C releases → true

## 2026-07-05 — `contrib/http/cache`: Cache-Control postures + ETag / 304

Rounds out the middleware family (session / basic_auth / csrf /
metrics / cache). Three helpers for the three canonical cache
postures plus an ETag + `If-None-Match` short-circuit:

- `cache_immutable seconds`
  Sets `Cache-Control: public, max-age=N, immutable`. For asset
  URLs with a content hash in the path.
- `cache_private seconds`
  Sets `Cache-Control: private, max-age=N`. For per-session pages
  that can be briefly re-used.
- `cache_no_store ()`
  Sets `Cache-Control: no-store, no-cache, must-revalidate` +
  `Pragma: no-cache`. For login / secrets / POST redirects.
- `etag body` — quoted SHA-256 hex, strong.
- `if_none_match tag` — reads `If-None-Match`, `str_eq` compare.
  Doesn't parse `*` wildcards or comma lists (documented).

Demo `examples/http_cache_demo.mere` verifies all three postures +
the 304 round-trip: matching `If-None-Match` → 304 with empty body,
mismatching → 200 with fresh ETag.

## 2026-07-05 — `contrib/db/redis_stream`: consumer groups (XGROUP / XREADGROUP / XACK / XPENDING)

Extends the stream module with the load-balanced worker pattern —
Redis' Kafka-consumer-group equivalent.

Added:

- `stream_group_create fd key group start_id` — XGROUP CREATE with
  MKSTREAM so producer/consumer bootstrap order is irrelevant.
  `"0"` = read from beginning, `"$"` = only new arrivals.
- `stream_group_read  fd key group consumer count` — XREADGROUP
  GROUP … `>` (un-delivered only). Server remembers per-consumer
  in-flight entries in the PEL.
- `stream_ack  fd key group ids` — XACK; returns n acked.
- `stream_pending_len fd key group` — XPENDING summary → total
  un-acked count.

XCLAIM / XAUTOCLAIM for reassigning stuck entries stays deferred.

Demo `examples/db_redis_stream_groups.mere` walks the full cycle:
one group `workers` with two consumers A + B share 4 XADD'd jobs.
XREADGROUP delivers 1-2 to A and 3-4 to B (no overlap — Redis
tracks what's been handed out). PEL sits at 4, then 2 after A
ACKs its half, then 0 after B ACKs. A follow-up XREADGROUP `>`
returns empty since the group is drained.

## 2026-07-05 — `contrib/db/redis_stream`: XADD / XREAD / XLEN

Third leg of the Redis event story:

    redis_pubsub    broadcast-and-forget, no history
    redis_queue     exactly-one-worker-claims (BRPOP)
    redis_stream    durable append-only log, replayable

Streams are Redis' Kafka-lite — entries live in an append-only radix
tree with server-generated `<ms>-<seq>` ids. Consumers either
resume from a chosen id or use consumer groups (deferred here).

Public API:

- `stream_add fd key fields         -> str option`
  XADD with `*` id, returns the new entry id.
- `stream_read fd key after_id N    -> (id, fields) list`
  XREAD COUNT N STREAMS key after_id. `after_id` is exclusive;
  use `"0"` for a full replay.
- `stream_len fd key                -> int`
  XLEN, `-1` on error.

Out of MVP scope: XREADGROUP / XACK / XPENDING consumer groups,
MAXLEN caps, blocking reads (XREAD BLOCK N). Documented in the
module header.

Demo `examples/db_redis_stream.mere` verifies the full flow: 3
XADDs → XLEN=3 → full replay from `0` recovers all fields → resume
from mid-stream id yields only the tail → past-the-tail returns
empty.

## 2026-07-05 — `contrib/http/csrf`: synchronizer-token CSRF middleware

Sits on top of `contrib/http/session`: the cookie session id is
the store key, the token is a fresh 16-hex random via
`gen_request_id ()` minted on first `csrf_token_for` per session
and re-used for the lifetime of the session.

Public API:

- `csrf_new_store ()`
- `csrf_token_for store session_id`      — idempotent per session
- `csrf_validate  store session_id tok`  — bool
- `csrf_hidden_input token`              — `<input type="hidden" name="_csrf" value="…">` snippet

Design choice: kept as primitives rather than a `with_csrf`
middleware because content-type detection (form vs JSON) and body
re-parsing are handler-specific concerns; handlers already read
the body via `form_field` / `body_field`, so passing the value
into `csrf_validate` is a one-liner where the caller already is.

Demo `examples/http_csrf_demo.mere` — a mutable-message form.
Verified: missing `_csrf` → 403, wrong token → 403, correct token →
303 redirect with the message actually persisting.

## 2026-07-05 — playground: `wordcount` demo + build tail-call flag

New live-docs demo — a client-side text stats tool: char / word /
line counters computed by a Mere function compiled to Wasm, wired
into a textarea + three display slots via `contrib/dom`. Reuses the
Phase 48 C2 frontend FFI (closure dispatch through the exported
function table); no new externs.

Files:

- `contrib/site/playground/wordcount.mere` — `count_words` /
  `count_lines` implemented as manual character scans (folds runs
  of whitespace into one word boundary; treats `\n` as line
  separator so an N-line file reports N).
- `contrib/site/playground/wordcount.html` — form + wire wasm,
  matches the styling of the counter / echo demos.
- Nav entry added to all sibling playground pages + the SSG's
  playground index.

Build fix: `contrib/site/build_full.sh` now invokes `wat2wasm
--enable-tail-call`. The wordcount demo emits `return_call` /
`return_call_indirect` (Wasm tail-call proposal) via its `while`
loop + inner-lifted closures, and the pre-flag site build rejected
those opcodes. Enabled by default in Chrome / Safari / Firefox 129+ /
Node 22+, so no runtime compatibility loss.

Live path: `https://merelang.github.io/mere/playground/wordcount.html`
after the next Pages deploy.

## 2026-07-05 — `contrib/db/redis_hll`: HyperLogLog cardinality estimators

Thin wrappers on Redis's `PF*` family. Approximate distinct-count
with fixed 12 KiB per key regardless of true cardinality (~0.81 %
standard error). Complements the exact-set path (`SADD` / `SCARD`)
for cases where the memory budget matters more than the exact
number — unique visitors, distinct URLs, unique IPs per hour.

- `hll_add fd key values` — PFADD; returns `1` if the estimate
  moved, `0` if all values were already there, `-1` on error.
- `hll_count fd keys` — PFCOUNT; approximate cardinality. Single
  key = that key's count; multiple keys = the union cardinality
  (server-side merge into a temp HLL).
- `hll_merge fd dest srcs` — PFMERGE; materializes the union of
  `srcs` into `dest`. Idempotent.

Demo `examples/db_redis_hll.mere` verifies both the union-via-
count and union-via-merge paths: 3 users on `shard-a`, 3 users on
`shard-b` (one overlap), true distinct = 5 across both, and both
merge paths report 5.

## 2026-07-05 — `contrib/log`: level filtering + field-taking variants + `LOG_LEVEL` env

The base `log_debug` / `log_info` / `log_warn` / `log_error`
functions were already there but always printed. Now:

- `set_log_level "debug" | "info" | "warn" | "error" | "off"` sets
  the threshold at runtime. Default remains `info`.
- `log_from_env ()` reads `LOG_LEVEL` from the process env. Unset
  or empty leaves the default in place — a demo without any
  explicit configuration still gets `info`-and-above.
- `log_debug_f` / `log_info_f` / `log_warn_f` / `log_error_f` —
  field-taking variants. Same filter applies; structured
  `(str, str) list` fields become JSON keys next to `msg`.

The threshold lives in a single-cell `vec_new ()` allocated once at
module-load time (post import-flatten). Note for future contrib
authors: module-level mutable state must use `;` (top-level decl)
rather than `let ... in` — the latter turns the rest of the file
into one expression that import discards. Learned the hard way
here; documented in the module.

Demo `examples/log_levels_demo.mere` exercises all levels + runtime
switching. Verified:
- default: info + warn + error + info_f + error_f visible.
- `LOG_LEVEL=debug`: debug included.
- `LOG_LEVEL=warn`: only warn + error.
- `LOG_LEVEL=off`: silent (until runtime `set_log_level` re-enables).

All 8 existing log consumers (`http_users_db`, `http_jwt_api`,
`http_ci_dashboard`, `http_feed_reader`, `http_csv_export`,
`http_wiki`, `http_file_upload`, `http_webhook_receiver`) recompile
unchanged. Test suite: 1846.

## 2026-07-05 — `contrib/http/basic_auth`: RFC 7617 Basic Auth middleware

Small addition to gate internal endpoints — `/metrics` scraping,
`/admin` dashboards, cron-triggered endpoints. Two entry points:

- `with_basic_auth realm user pass handler` — single credential pair
  (compile-time constant).
- `with_basic_auth_pred realm predicate handler` — delegate the
  credential check to a `(user, pass) -> bool` predicate. Useful
  when the accepted set comes from an env var or in-process map.

Missing / wrong credentials → 401 with `WWW-Authenticate: Basic
realm="…", charset="UTF-8"`. Handler is NOT called on failure.
Simple `str_eq` compare (not timing-safe) — documented as a gate,
not a production auth layer.

Added `base64_encode` / `base64_decode` externs to `scripts/pg_env.js`
for utf8 <-> standard-alphabet base64 round-trip (the existing
`_hex` variants take a hex detour that's overkill for Basic Auth's
plain `user:pass` payload).

`examples/http_metrics_demo.mere` gained a Basic-Auth-gated
`/metrics` route as the first consumer. Verified: no-auth → 401,
wrong creds → 401, `-u scraper:s3cret` → 200 with metrics body.
Ungated routes (`/`, `/work`) still return 200.

## 2026-07-05 — Blog-engine papercuts: lexer + typer polish

Two friction points surfaced during the http_blog dogfood get proper
first-class fixes now (previously the demo worked around them).

**String line-continuation.** `"foo \<newline>   bar"` now lexes as
`"foo bar"` — the backslash-newline sequence eats the newline itself
plus any leading spaces / tabs on the next line (Python / Rust
convention). Long HTML snippets, SQL statements, and log messages
can be broken across source lines without smuggling in a `\n` or
indent characters, and without piecing them back with `++` string
concatenation. All existing escapes (`\n`, `\t`, `\r`, `\"`, `\\`,
`\{`) still work identically.

**SCREAMING_SNAKE_CASE hint on `let`.** `let DB_URL = "..."` used to
fail with a bare `type error: unknown constructor in pattern: DB_URL`
because Mere reserves uppercase-first identifiers for constructors.
The typer now recognises the shape (starts uppercase, has no
lowercase letters, either ≥ 3 chars OR contains `_`) and adds:

    help: Mere reserves uppercase-first identifiers for constructors.
    If you meant a value binding, rename to `db_url`.

The heuristic explicitly excludes single-letter names like `let X = …`
(too plausibly a one-shot constructor placeholder) and still yields
to the standard did-you-mean suggestion when one exists (`let x = Cnos (…)`
→ `did you mean 'Cons'?`).

Both changes come with regression tests. Full suite: 1838 → 1846.

## 2026-07-05 — `sse_bridge_from_redis`: multi-instance SSE fanout

New extern in `contrib/http/sse.mere`:

    sse_bridge_from_redis channel host port -> unit

Spins up (or reuses — idempotent per channel) a persistent RESP2
subscriber in the Node runner. Every incoming `message`-shaped
reply on `channel` is forwarded to the JS-side SSE broadcast for
the same channel name. Result: N Mere HTTP instances behind a
load balancer, all subscribed to the same Redis channel, deliver
posted messages to every SSE client regardless of which instance
holds the subscription.

Two moving parts:

- `scripts/sse_redis_bridge.js` — new. Async RESP2 subscriber
  (Node's `net.Socket`), auto-reconnect on error / close with a
  1 s backoff. Parser handles arrays / bulks / simple strings /
  integers — enough for the SUBSCRIBE reply shape.
- `contrib/http/http.glue.js` — factored the inner fanout code out
  of the Mere-facing `sse_broadcast` extern into a JS-callable
  `broadcast(channel, payload)` helper. `makeHttpGlue()` now
  returns `{ glue, attach, broadcast }`; the bridge factory
  receives `broadcast` and calls it directly (no Mere-heap ptr
  boundary crossing).

Demo `examples/http_pubsub_chat.mere` verifies end-to-end:

- Two instances started on `:8080` + `:8081` against a shared
  Redis; both subscribe to `chat`.
- POST to `:8080` returns `{"delivered_to":2}` (Redis sees two
  subscribers) and the message appears on BOTH SSE streams.
- POST to `:8081` — same behaviour in reverse.

`http_serve` and the pubsub subscriber coexist because the
subscribe socket lives entirely in JS (Node's event loop),
avoiding Mere's single-threaded per-frame constraint.

## 2026-07-05 — `contrib/http/session`: consolidate cookie-session pattern

Seven demos (http_blog, http_todo_app, http_users_db, http_todo_pg,
http_mini_blog, http_feed_reader, http_cookie_session) all
hand-rolled the same five-line dance: `map_new ()`, read `session=`
cookie, look up user, mint id on login, `Set-Cookie`. Consolidate:

- `session_new_store ()` — opaque store handle (a `map` under the
  hood; pre-migration demos still compile against `map_has` etc.).
- `session_current store` — current user id or `""`.
- `session_login store user` — mints a random 16-hex id via
  `gen_request_id ()`, sets `Set-Cookie: session=…; Path=/;
  HttpOnly; SameSite=Lax`.
- `session_logout store` — removes the entry + emits `Max-Age=0`.
- `session_require store login_url` — returns `str option`; `None`
  side-effects a 303 to `login_url`.

Behavioural upgrade: sessions now use `gen_request_id ()` (crypto
random) instead of the demos' old `"s-" ++ username` — non-guessable
ids, plus `HttpOnly; SameSite=Lax` cookie attributes by default.

`examples/http_blog.mere` migrated as the first consumer. All six
CRUD flows still work end-to-end (login → post → view → edit →
delete). The other six demos continue to work unchanged and can
migrate incrementally.

## 2026-07-05 — `contrib/http/metrics`: Prometheus-style metrics + middleware

A small registry of counters and gauges plus a text-format exporter
and a `GET /metrics` handler suitable for direct mount in a route
table. Ships an auto-counting middleware `with_metrics` that
increments `http_requests_total{method, path}` and adds request
duration into `http_request_duration_ms_sum` + `_count` for every
request (Prom's "summary" idiom, no percentiles).

Public API:

- `metric_declare_counter name help` / `metric_declare_gauge name help`
  — register + attach HELP/TYPE metadata (rendered once per name).
- `metric_inc name labels` — counter += 1.
- `metric_add name labels n` — counter += n.
- `metric_set name labels v` — gauge = v.
- `metrics_render ()` — Prometheus text-format string.
- `metrics_handler req` — mount as `GET /metrics`.
- `with_metrics handle` — middleware wrapper.

Storage is a plain `map_new ()` keyed by `name` or `name{labels}`;
values are `int` (millisecond durations, counts). Float values,
configurable histogram buckets, and label-value escaping are out
of MVP scope.

Also added `now_ms` extern to `run_wasm.js` (previously only in
`run_http_server.js`) so contrib modules that pull it work under
either runner.

Demo `examples/http_metrics_demo.mere` — four routes (`/`, `/work`
with a 50 ms sleep, `POST /error`, `/metrics`) verify the auto-
counters, business counters, and duration accumulation. `/work`'s
`http_request_duration_ms_sum` sits at ~55 ms after one hit;
`errors_total` increments only on `POST /error`.

## 2026-07-05 — `examples/gh_stars`: first CLI demo

First Mere program that runs under `run_wasm.js` (not
`run_http_server.js`) and makes outbound HTTP calls. Fetches
`https://api.github.com/repos/<owner>/<repo>` and prints the star
count, using:

- `arg_get 0` for `owner/repo` argv.
- `getenv "GITHUB_TOKEN"` for optional Bearer auth (60 → 5000
  req/hour when set).
- `http_fetch_h` for the `Accept: application/vnd.github+json` +
  `User-Agent` headers.
- `http_fetch_response_header "X-RateLimit-Remaining"` for the
  rate-limit metadata line.
- Naive `"stargazers_count":<n>` scanner (avoids pulling in
  `contrib/json` which has a top-level self-test block that would
  execute on import).

Verified against `merelang/mere` (0 stars, fresh repo),
`rust-lang/rust` (114325), `sindresorhus/awesome` (481588), and a
404 path (`no-such-owner/no-such-repo-12345` → HTTP 404 with the
response body printed).

## 2026-07-05 — `redis_pubsub_run_forever` + `sleep_ms` extern + tcp_worker `end`-event fix

Three related changes to make a real-world reconnecting subscribe
loop possible in pure Mere.

**`redis_pubsub_run_forever host port sub timeout_ms retry_ms handler`**
Opens its own sub fd, sends the `SUBSCRIBE` / `PSUBSCRIBE` commands
from `sub`, dispatches messages via `handler`, and on `PSClosed`
(or `redis_connect` failure) sleeps `retry_ms` then starts over.
The handler receives `PSClosed` events too, so it can log / reset
metrics / decide to bail (returning `false` from any invocation
ends the loop cleanly). Non-draining `redis_pubsub_subscribe`
variants are used so `PSSubscribed` events flow through the
handler on every reconnect.

Subscription state is captured in a new `PubsubSub` record —
`{ channels; patterns }`.

**`sleep_ms` extern** — synchronous millisecond sleep via
`Atomics.wait` on a private `SharedArrayBuffer`. Blocks the whole
Wasm frame, so an HTTP server MUST NOT call this inside a request
handler. Added to both `run_wasm.js` and `run_http_server.js` (both
had a no-op `sleep`).

**tcp_worker.js `end`-event handler** — with `allowHalfOpen: true`,
a peer FIN emitted `end` but not `close`, so a pending
`tcp_read` hung indefinitely. Reproducible via `CLIENT KILL TYPE
PUBSUB` on a subscribed connection. Added an `on('end', ...)`
handler that marks the socket read-closed and wakes any pending
read with EOF (`respond(0, 0)`), matching what the `close` branch
already did.

Demo `examples/db_redis_pubsub_reconnect.mere` stages the failure
in one process: subscribe → publish 2 → 2 deliveries → send
`CLIENT KILL TYPE PUBSUB` → sub fd closes → loop sleeps 500 ms →
reconnects + resubscribes → publish 2 more → 2 deliveries → exit.

Verified end-to-end against redis:7, plus the existing base pubsub
+ queue demos still work unchanged (regression check). 1838-test
OCaml suite passes.

## 2026-07-05 — `contrib/db/redis_queue`: list-backed work queue

Complements `redis_pubsub`. Pub/sub is broadcast-and-forget; work
queues are exactly-one-worker-claims-each-job. Standard Redis
reliable-queue pattern wrapped:

- `redis_queue_push fd queue payload` — LPUSH, returns new length.
- `redis_queue_pop fd queue timeout_s` — BRPOP with server-side
  block. `Some (queue, payload)` on delivery, `None` on timeout.
  Client-side socket timeout is set to `(timeout_s + 5) s` as a
  safety net; `timeout_s == 0` blocks forever on both sides.
- `redis_queue_pop_many fd queues timeout_s` — priority multi-queue
  BRPOP. Earlier queues in the list win.
- `redis_queue_len fd queue` — LLEN.
- `redis_queue_run fd queues timeout_s handler` — event-loop helper
  that retries on timeout; handler returns `false` to break out.

Explicitly out of scope for the MVP: ack / retry semantics
(processing-list + RPOPLPUSH reconciliation), delayed jobs, and
priorities beyond the multi-queue trick.

Demo `examples/db_redis_queue.mere` verifies push (returns
1,2,3,4), LLEN=4, FIFO order across three BRPOPs, priority fall-
through via `pop_many ["jobs.slow"; "jobs"]`, and the empty-queue
timeout returning `None`.

## 2026-07-05 — `http_fetch` shared across both runners

`http_fetch` and friends now live in `scripts/http_fetch_env.js` and
plug into both `run_http_server.js` (as before) and `run_wasm.js`
(new). Any Mere CLI that declares `extern fn http_fetch: ...` can
now make outbound calls under the plain runner — previously they
had to boot the HTTP server runner just to get the extern env.

`examples/http_client_auth.mere` dropped its unused
`extern fn http_serve` declaration and runs identically under both
runners (verified against httpbin.org).

Also refreshed `docs/http-demos.md`: added a "Router API" primer
covering `route` / `route_pattern` / `route_prefix`, and catalog
entries for the recent `blog` and `client_auth` demos.

## 2026-07-05 — `contrib/http/client`: request + response headers, per-call timeout

The outbound `http_fetch` was fixed to a bare `(method, url, body)`
shape — no way to attach an `Authorization: Bearer …` header, no
way to read a `Retry-After` back off a 429, no way to shorten the
10 s default timeout for a cheap probe. Three new externs close
that gap without breaking the existing 3-arg call:

- `http_fetch_add_header name value` — attaches a header to the
  NEXT fetch (host-side accumulator is cleared once the fetch
  fires, so a set-and-fetch pair is self-contained).
- `http_fetch_response_header name` — case-insensitive lookup on
  the LAST response. Only the final response block is exposed —
  redirect chains and 100-continue trailers are discarded.
- `http_fetch_set_timeout ms` — one-shot override; 0 restores the
  10 s default.

Ergonomic wrappers in `contrib/http/client.mere`:

- `http_fetch_h method url body headers` — headers as `(str * str) list`.
- `http_get_bearer url token` — sugar over the common auth-header case.

`scripts/run_http_server.js` runs curl with `-i` and parses the
final response header block (handling redirect / 100-continue
prefaces by taking the LAST `HTTP/…` block) so the host doesn't
need a temp file for header capture.

Demo `examples/http_client_auth.mere` verifies all four features
end-to-end against httpbin.org: custom header round-trip, response
header read, Bearer token, per-call timeout enforcement.

## 2026-07-04 — `contrib/db/redis_pubsub`: dispatch layer

`redis.mere` already carried the raw `SUBSCRIBE` / `PSUBSCRIBE` /
`PUBLISH` primitives, but callers had to destructure the resulting
RRArr replies by hand to tell a `message` from a `pmessage` from a
`subscribe` confirmation. A separate module now does the
classification once and returns a small variant:

```
type pubsub_msg =
  | PSMessage      of str * str          — (channel, payload)
  | PSPMessage     of str * str * str    — (pattern, channel, payload)
  | PSSubscribed   of str * int
  | PSUnsubscribed of str * int
  | PSPong         of str
  | PSTimeout
  | PSClosed
  | PSOther        of redis_reply
```

- `redis_pubsub_next fd timeout_ms` — read + classify one reply.
  Uses the caller's `timeout_ms` to disambiguate the "short read"
  case: > 0 → `PSTimeout`, else `PSClosed`.
- `redis_pubsub_run fd timeout_ms handler` — event-loop helper;
  handler returns `false` to break out, loop also exits on
  `PSClosed`.
- `redis_pubsub_subscribe` / `redis_pubsub_psubscribe` — non-draining
  variants that leave the confirmation reply on the wire, so the
  dispatch loop sees each as a `PSSubscribed` event.
- `redis_pubsub_open host port` — two-fd `PubsubClient` record
  (publisher + subscriber connections) encapsulating Redis's
  "PUBLISH needs its own fd" rule.
- `redis_pubsub_show msg` — one-line pretty-printer for access logs.

`examples/db_redis_pubsub.mere` rewritten to demonstrate the whole
API, including PSUBSCRIBE with a matched-pattern delivery and a
`PSTimeout` tick. Full RESP3 push (`RRPush`) is also routed through
the classifier by recursing into the inner list.

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
- **Phase 32.0**: FFI design — fixed syntax / typing /
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

