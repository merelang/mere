#!/bin/sh
# scripts/coro_check.sh — same-thread coroutines (coro_new / coro_switch / coro_self).
#
# A coroutine is a second stack on the thread that made it. Swapping the
# registers is the easy part; what a switch must ALSO carry is every piece of
# runtime state that belongs to a stack rather than to a thread. On the native
# backends that is four things -- the current region, the live-block stack
# (what a fail unwinds), the innermost try_or's jmpbuf, and the stack bounds the
# SIGSEGV handler compares a fault against (LLVM adds its ListBuf depth word).
# Leave any one on the thread and the program reads freed memory, releases
# another stack's blocks, longjmps onto a stack that is not running, or calls
# its own overflow a segfault.
#
# WHAT IS CHECKED: every fixture in test/coro/ gives its expected first lines
# and exit status, on the interpreter, on C and on LLVM (both at -O0 and -O2).
# The overflow fixtures are native only: whether that recursion fits is a fact
# about the default stack size, and the interpreter's stack is not a native
# one. env differs on LLVM by design: its closures carry no env copier, so a
# coroutine made inside a block is refused there by name.
#
# COMPACTION: a map compacted while a suspended coroutine holds a pointer into
# its arena must not free that arena (C: it is retired and freed later; the
# LLVM backend has no map_compact, so the fixture is interp + C).
#
# THE REFUSALS: a body that captures a block's container is a type error (its
# env is copied out of the block, and a container's copy is the same handle);
# a Coro cannot be sent or captured across a thread; Wasm and RV name the
# builtin and the reason.
#
# --poison: the emitted C, then the emitted IR, is edited to drop one carried
# piece (or one check) at a time, and the fixture that exists for it must go
# red. A fixture that stays green without the fix is not measuring it.
#
# Usage:
#   sh scripts/coro_check.sh            # check
#   sh scripts/coro_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "coro: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "coro: no C compiler — skipping"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MODE="${1:-}"
LIMIT="${LIMIT:-60}"
FX="$ROOT/test/coro"
fail=0

# fixture | backends (i interp, c C, l LLVM) | expected output (lines joined with ;) | exit
CASES='region|icl|B: my string survived;4106|0
fail|icl|fail: from the coroutine|1
nested|icl|main caught: -1;B caught: 5;main: done|0
unwind|icl|B: region R2 survived main'"'"'s unwind;4096|0
env|ic|env: intact;8192|0
env|l|coro_new: inside a region block -- on LLVM the body'"'"'s env would be released with the block (the C backend copies it out)|1
finished|icl|B: ran;switch to a finished coroutine: refused|0
self_handoff|icl|coro: a finished coroutine must hand over to another live coroutine|1
many|icl|10000|0
pingpong|icl|1000000|0
overflow|cl|stack overflow (recursion too deep)|1
deep/deep|cl|2000001000000;main: back|0
compact|ic|held: intact;700|0
scan|icl|all found, bound kept;running: found;57573|0
scan_high|cl|found, again found, small left out;7;12|0
transfer|icl|int: 1 12 23, float: 3.75;bool: true then false, coro: hopped;after the end: 0|0
notme|icl|coro_transfer: the third argument must be the running coroutine|1
sized|icl|5050;45000150000;partial|0
sized_overflow|cl|stack overflow (recursion too deep)|1
sized_reuse|icl|small;200010000;done|0
region_cross|icl|kept;32|0
compact_reuse|ic|held;0|0'

# The interpreter prints a failure with its position and a code frame; the
# compiled program prints the message alone. The comparison is on the message.
norm() {
  sed -e 's/^eval error: //' -e 's/^[^ ]*\.mere: eval error: //' | grep -v '^ *-->\|^ *|\|^ *[0-9]* |\|^$' | head -3 | tr '\n' ';' | sed 's/;$//'
}

run_bounded() {  # $@ = command -> "output|exit"
  perl -e 'alarm shift; exec @ARGV' "$LIMIT" "$@" > "$T/out" 2>&1
  rc=$?
  [ "$rc" = 142 ] && { echo "TIMEOUT|142"; return; }
  printf '%s|%s' "$(norm < "$T/out")" "$rc"
}

build() {  # $1 = fixture, $2 = opt, $3 = c|ll, [$4 = sed expression] -> $T/bin, or prints why not
  "$MERE" "-$3" "$FX/$1.mere" > "$T/g.$3" 2>"$T/emit.err" || { echo "EMITFAIL $(head -1 "$T/emit.err")"; return 1; }
  if [ -n "${4:-}" ]; then
    sed "$4" "$T/g.$3" > "$T/p.$3"
    if cmp -s "$T/p.$3" "$T/g.$3"; then echo "SEDNOMATCH"; return 1; fi
    mv "$T/p.$3" "$T/g.$3"
  fi
  "$CC" "$2" -w -o "$T/bin" "$T/g.$3" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(head -1 "$T/cc.err")"; return 1; }
}

want_of() {  # $1 = fixture, $2 = backend letter -> "expected|exit"
  printf '%s\n' "$CASES" | while IFS='|' read -r f b w rc; do
    case "$b" in *"$2"*) [ "$f" = "$1" ] && printf '%s|%s' "$w" "$rc" ;; esac
  done
}

printf '%s\n' "$CASES" > "$T/cases"
while IFS='|' read -r f b w rc; do
  case "$b" in *i*)
    got=$(run_bounded "$MERE" "$FX/$f.mere")
    if [ "$got" = "$w|$rc" ]; then printf '  ok    %s\n' "interp $f"
    else printf '  FAIL  %s\n' "interp $f: got [$got] wanted [$w|$rc]"; fail=1; fi ;;
  esac
  for be in c ll; do
    case "$be" in c) letter=c; name=C ;; ll) letter=l; name=LLVM ;; esac
    case "$b" in *"$letter"*) ;; *) continue ;; esac
    for opt in -O0 -O2; do
      if ! why=$(build "$f" "$opt" "$be"); then printf '  FAIL  %s\n' "$name $opt $f: $why"; fail=1; continue; fi
      got=$(run_bounded "$T/bin")
      if [ "$got" = "$w|$rc" ]; then printf '  ok    %s\n' "$name $opt $f"
      else printf '  FAIL  %s\n' "$name $opt $f: got [$got] wanted [$w|$rc]"; fail=1; fi
    done
  done
done < "$T/cases"

# --- what a finished coroutine keeps ---------------------------------------
# A million made and finished must stay small. On C (v0.1.558) a finished
# coroutine keeps NOTHING -- its record is freed at reap and its handle carries
# a generation, its env was its own -- and a correct run holds about 1.5 MiB:
# the cap is 16 MiB, and a runtime that kept the 24-byte records (34 MiB) is
# over it. LLVM is the same since v0.1.565 (slot table, record freed at reap,
# the lambda's env its own): 1.5 MiB, under the same cap -- it held 33.7 MiB
# with the records and 49.7 with an env per coroutine.
RSS_CAP_C=16777216
RSS_CAP_LL=16777216
cap_for() { if [ "$1" = c ]; then printf '%s' "$RSS_CAP_C"; else printf '%s' "$RSS_CAP_LL"; fi; }
rss_of() {  # $1 = binary -> resident bytes, or empty when this host cannot say
  r=$( { /usr/bin/time -l "$1" >/dev/null; } 2>&1 | awk '/maximum resident/ {print $1}' )
  [ -n "$r" ] || r=$( { /usr/bin/time -v "$1" >/dev/null; } 2>&1 | awk '/Maximum resident/ {print $6 * 1024}' )
  printf '%s' "$r"
}
for be in c ll; do
  name=C; [ "$be" = ll ] && name=LLVM
  if ! why=$(build million -O2 "$be"); then printf '  FAIL  %s\n' "$name million: $why"; fail=1; continue; fi
  r=$(rss_of "$T/bin")
  if [ -z "$r" ]; then printf '  FAIL  %s\n' "$name million: no /usr/bin/time here, so the question was not asked"; fail=1
  elif [ "$r" -lt "$(cap_for "$be")" ]; then printf '  ok    %s\n' "$name: a million finished coroutines hold $((r / 1048576)) MiB"
  else printf '  FAIL  %s\n' "$name: a million finished coroutines hold $((r / 1048576)) MiB"; fail=1; fi
done

# --- refusals -------------------------------------------------------------
refuse() {  # $1 = label, $2 = flag ("" = interpreter), $3 = program, $4 = text the refusal must contain
  printf '%s\n' "$3" > "$T/r.mere"
  if [ -n "$2" ]; then "$MERE" "$2" "$T/r.mere" > /dev/null 2> "$T/r.err"; rc=$?
  else "$MERE" "$T/r.mere" > /dev/null 2> "$T/r.err"; rc=$?; fi
  if [ "$rc" != 0 ] && grep -qF -- "$4" "$T/r.err"; then printf '  ok    %s\n' "refused: $1"
  else printf '  FAIL  %s\n' "not refused: $1 (exit $rc: $(head -1 "$T/r.err"))"; fail=1; fi
}
refuse "a body capturing a block's Vec" "" 'let root = coro_root ();
let c = region R { let v = vec_new () in let _ = vec_push v 1 in coro_new (fn _me -> fn (_u: unit) -> coro_exit ( let _ = print_int (vec_len v) in root) ()) };
coro_switch c' 'coro_new: the body captures `v`'
refuse "a body capturing a block's Vec (C)" -c 'let root = coro_root ();
let c = region R { let v = vec_new () in let _ = vec_push v 1 in coro_new (fn _me -> fn (_u: unit) -> coro_exit ( let _ = print_int (vec_len v) in root) ()) };
coro_switch c' 'coro_new: the body captures `v`'
refuse "a Coro sent over a channel" "" 'let ch = channel_new ();
let _ = channel_send ch (coro_root ());
0' '`unit Coro` is not Send'
refuse "a Coro captured by spawn" "" 'let c = coro_root ();
let h = spawn (fn () -> coro_switch c);
join h' 'cannot capture `c` : unit Coro across a thread boundary'
# v0.1.561 (Q-184): what a message may be, the API that went, and the shape that changed
refuse "a str message" "" 'let root = coro_root ();
let c = coro_new (fn me -> fn (m: str) -> coro_exit root ());
0' "a coroutine's messages are int, bool, float, unit or a Coro for now -- this one's are str"
refuse "coro_self, removed" "" 'let r = coro_self (); 0' 'removed in v0.1.561'
refuse "a body of the old shape" "" 'let c = coro_new (fn () -> coro_root ()); 0' 'a body is `fn me -> fn msg -> ..` since v0.1.561'
refuse "a message type fixed once" "" 'let root = coro_root ();
let c = coro_new (fn me -> fn m -> coro_exit root ());
let _ = coro_transfer c 1 root;
let _ = coro_transfer c true root;
0' 'expected `int`, got `bool`'
refuse "Wasm names it" -w 'coro_switch (coro_root ())' 'is not available on Wasm'
# v0.1.623: RISC-V has coroutines (the section below); as a VALUE a builtin is
# still refused there, with the reason
refuse "RV64 names one passed as a value" -rv64 'let f = coro_switch in f (coro_root ())' 'is unsupported here as a value'
refuse "Wasm names coro_scan_ints" -w 'coro_scan_ints (coro_root ()) 0 1 (fn (n: int) -> ())' 'is not available on Wasm'

# and what must NOT be refused: a block's VALUE is copied out with the env
printf '%s\n' 'let root = coro_root ();
let c = region R { let s = str_repeat "x" 3 in coro_new (fn _me -> fn (_u: unit) -> coro_exit ( let _ = print s in root) ()) };
let _ = region Z { str_len (str_repeat "Z" 4096) };
coro_switch c' > "$T/ok.mere"
got=$("$MERE" -c "$T/ok.mere" 2>&1 > "$T/ok.c") || true
if "$CC" -w -o "$T/ok" "$T/ok.c" -lm -lpthread 2>/dev/null && [ "$("$T/ok")" = "xxx" ]; then
  printf '  ok    %s\n' "allowed: a body capturing a block's str (copied with the env)"
else
  printf '  FAIL  %s\n' "a body capturing a block's str: $got"; fail=1
fi

# --- RISC-V (v0.1.623) ------------------------------------------------------
# On the Mere-written CPU, both widths, when MEMU names a memu checkout (as
# rv_exec_check does). The runtime is the RV prelude's rvcoro_ functions over
# __rv_cswap, which copies each coroutine's stack in and out of one region; the
# per-stack words it carries are the try_or record, the region depth and the
# two block marks. RV's own spellings: a failure prints its message alone
# (no `fail: `), and `scan_high` (a 2^48 literal) and `sized` (a sum past 2^31)
# are RV64 only. The OUTPUT is compared, not the exit status: memu exits 0
# whatever the guest's exit call said.
# fixture | r both widths, q RV64 only | expected | (exit, as on C; not compared)
RV_CASES='region|r|B: my string survived;4106|0
fail|r|from the coroutine|1
nested|r|main caught: -1;B caught: 5;main: done|0
unwind|r|B: region R2 survived main'"'"'s unwind;4096|0
env|r|env: intact;8192|0
finished|r|B: ran;switch to a finished coroutine: refused|0
self_handoff|r|coro: a finished coroutine must hand over to another live coroutine|1
many|r|10000|0
pingpong|r|1000000|0
compact|r|held: intact;700|0
scan|r|all found, bound kept;running: found;57573|0
scan_high|q|found, again found, small left out;7;12|0
transfer|r|int: 1 12 23, float: 3.75;bool: true then false, coro: hopped;after the end: 0|0
notme|r|coro_transfer: the third argument must be the running coroutine|1
sized|q|5050;45000150000;partial|0
sized_overflow|r|stack overflow (recursion too deep)|1
sized_reuse|r|small;200010000;done|0
million|r|1000000|0
region_cross|r|kept;32|0
compact_reuse|r|held;0|0'
RV_LIMIT="${RV_LIMIT:-300}"
have_rv=0
if [ -n "${MEMU:-}" ] && [ -f "$MEMU/riscv-runc/rv64i_run.mere" ]; then
  mkdir -p "$T/rv"
  if "$MERE" -c "$MEMU/riscv-runc/rv64i_run.mere" > "$T/rv/r64.c" 2>/dev/null \
     && "$CC" -O2 -w -o "$T/rv/rvrun64" "$T/rv/r64.c" -lm 2>/dev/null \
     && "$MERE" -c "$MEMU/riscv-runc/rv32i_run.mere" > "$T/rv/r32.c" 2>/dev/null \
     && "$CC" -O2 -w -o "$T/rv/rvrun32" "$T/rv/r32.c" -lm 2>/dev/null; then have_rv=1
  else printf '  FAIL  %s\n' "RISC-V: the emulator under MEMU=$MEMU did not build"; fail=1; fi
fi
run_rv() {  # $1 = fixture, $2 = 32|64 -> "output|exit" (MERE_RV_PRELUDE_FILE passes through)
  flag=-rv64; [ "$2" = 32 ] && flag=-rv
  # `sized` asks for a 64 MB stack and recurses 300,000 deep in it
  extra=""; [ "$1" = sized ] && extra="--coro-stack 64"
  # shellcheck disable=SC2086
  if ! "$MERE" "$flag" --ram 256 $extra "$FX/$1.mere" > "$T/rv/prog.bin" 2>"$T/rv/emit.err"; then
    printf 'EMITFAIL %s|x' "$(grep -v '^warning\|^ *-->\|^ *|\|^ *[0-9]* |\|^ *= \|^$' "$T/rv/emit.err" | head -1)"; return
  fi
  ( cd "$T/rv" && perl -e 'alarm shift; exec @ARGV' "$RV_LIMIT" ./rvrun"$2" 256 > out 2>&1 ); rc=$?
  [ "$rc" = 142 ] && { echo "TIMEOUT|142"; return; }
  printf '%s' "$(grep -av '^rvrun' "$T/rv/out" | norm)"
}
if [ "$have_rv" = 1 ]; then
  printf '%s\n' "$RV_CASES" > "$T/rvcases"
  while IFS='|' read -r f b w rc; do
    for width in 64 32; do
      [ "$b" = q ] && [ "$width" = 32 ] && continue
      got=$(run_rv "$f" "$width")
      if [ "$got" = "$w" ]; then printf '  ok    %s\n' "RV$width $f"
      else printf '  FAIL  %s\n' "RV$width $f: got [$got] wanted [$w]"; fail=1; fi
    done
  done < "$T/rvcases"
else
  printf '  SKIP  %s\n' "RISC-V (set MEMU to a memu checkout)"
fi

if [ "$MODE" = "--poison" ]; then
  pfail=0
  poison() {  # $1 = c|ll, $2 = label, $3 = sed expression, $4... = fixtures that must go red
    be="$1"; label="$2"; ex="$3"; shift 3
    letter=c; [ "$be" = ll ] && letter=l
    for f in "$@"; do
      if ! why=$(build "$f" -O2 "$be" "$ex"); then
        printf '  FAIL  %s\n' "POISON $label: $f: $why -- the runtime no longer has the shape this poison removes"
        pfail=1; continue
      fi
      got=$(run_bounded "$T/bin")
      w=$(want_of "$f" "$letter")
      if [ "$got" = "$w" ]; then
        printf '  FAIL  %s\n' "POISON $label: $f still green without it"
        pfail=1
      else
        printf '  ok    %s\n' "POISON $label: $f goes red ([$got])"
      fi
    done
  }
  poison c "C 1 (current region not carried)" '/^  __lang_current_region = to->x->s_cur;$/d' region
  poison c "C 2 (live-block stack not carried)" '/^  __lang_region_active = to->x->s_active; __lang_region_active_n = to->x->s_active_n;$/d' unwind
  poison c "C 3 (try_or jmpbuf not carried)" '/^  __lang_fail_jmpbuf_set = to->x->s_jb_set;$/d' fail nested
  poison c "C 4 (stack bounds not carried)" '/^  __lang_stack_lo = to->x->s_lo; __lang_stack_hi = to->x->s_hi;$/d' overflow
  # v0.1.558: the env is the coroutine's own -- malloc'd where the lambda is
  # written, or copied into the coroutine by coro_new. Left in the block means
  # both undone: allocated in the current region, and not copied out.
  poison c "C 5 (env left in the block)" 's/__lang_env_alloc(\&__lang_coro_env_owner, /__lang_region_alloc(__lang_current_region, /; s/__env->__r = \&__lang_coro_env_owner;/__env->__r = __lang_current_region;/; s/^    if (h->__copy) { env = h->__copy(\&__lang_coro_env_owner, env); owned = 1; }$/    ;/' env
  # v0.1.558: a reaped coroutine is known by its handle's generation
  poison c "C 6 (no finished check)" '/^  if (!to) __lang_fail_impl/d; /^  if (to->state == 3) __lang_fail_impl/d' finished
  # v0.1.590: since v0.1.589 a pinned map is not compacted at all, and the retire
  # step asks who pinned the arena -- so freeing it under the stack takes both
  # checks gone (the old single pattern no longer matched anything)
  poison c "C 9 (an arena a suspended stack points into is freed)" 's/^  if (m->owns_region \&\& __lang_region_pinned \&\& __lang_region_pinned(m->region, 0)) return 0;$/  if (0) return 0;/; s/^  if (__lang_region_pinners) {$/  if (0) {/' compact
  poison c "C 7 (no hand-over check)" 's/^  if (!next || next == self || next->state == 3)$/  if (!next)/' self_handoff
  poison c "C 10 (a pointer into a live block is not followed)" 's/^    if (st->nsp == 0 || a < st->sp\[0\]\.lo || a >= st->sp\[st->nsp - 1\]\.hi) continue;$/    continue;/' scan
  poison c "C 11 (suspended stacks are not read)" 's/^    __lang_scan_words(&st, (uintptr_t\*)c->x->sp, (uintptr_t\*)c->x->s_hi, 0);$/    ;/' scan scan_high
  poison c "C 13 (the coroutine's own regions are not followed to the end)" 's/^    int own = (a0 < st->nown \&\& st->ownb\[a0\] == hdr);$/    int own = 0;/' scan
  # (No poison for the three-hop depth: a stack keeps stale slots that still
  # point at the inner nodes, so "one hop is not enough" cannot be made to
  # hold -- measured green at 1. C 10 is what shows the following matters.)
  poison c "C 12 (the running stack is not read)" 's/^  if (running) {$/  if (0) {/' scan
  poison ll "LLVM 1 (current region not carried)" '/^  store ptr %tr, ptr @__lang_current_region$/d' region
  poison ll "LLVM 2 (live-block stack not carried)" '/^  store ptr %ta, ptr @__lang_region_active$/d' unwind
  poison ll "LLVM 3 (try_or jmpbuf not carried)" '/^  store i32 %tjs, ptr @__lang_fail_jmpbuf_set$/d' fail nested
  poison ll "LLVM 4 (stack bounds not carried)" '/^  store i64 %tlo, ptr @__lang_stack_lo$/d; /^  store i64 %thi, ptr @__lang_stack_hi$/d' overflow
  poison ll "LLVM 5 (a block's coroutine not refused)" 's/^  br i1 %inblock, label %refuse, label %alloc$/  br label %alloc/' env
  # v0.1.565: a finished coroutine is a handle that no longer resolves
  poison ll "LLVM 6 (no finished check)" 's/^  br i1 %gone, label %finished, label %go$/  br label %go/' finished
  # v0.1.566: the pool keeps stacks apart by size
  poison c "C 15 (the pool hands out a stack of another size)" 's/^    if (__lang_coro_pools\[i\].size != size || !__lang_coro_pools\[i\].head) continue;$/    if (!__lang_coro_pools[i].head) continue;/' sized_reuse
  poison ll "LLVM 15 (the pool hands out a stack of another size)" 's/^  %ok = and i1 %same, %some$/  %ok = and i1 %some, %some/' sized_reuse
  poison ll "LLVM 7 (no hand-over check)" 's/^  br i1 %bad0, label %nowhere, label %chk$/  br label %chk/' self_handoff
  poison_rss() {  # $1 = c|ll, $2 = label, $3 = sed expression
    if ! why=$(build million -O2 "$1" "$3"); then
      printf '  FAIL  %s\n' "POISON $2: $why -- the runtime no longer has the shape this poison removes"; pfail=1; return
    fi
    r=$(rss_of "$T/bin")
    if [ -z "$r" ]; then printf '  FAIL  %s\n' "POISON $2: no /usr/bin/time here, so the question was not asked"; pfail=1
    elif [ "$r" -ge "$(cap_for "$1")" ]; then printf '  ok    %s\n' "POISON $2: million goes red ($((r / 1048576)) MiB)"
    else printf '  FAIL  %s\n' "POISON $2: million still under the cap without it ($((r / 1048576)) MiB)"; pfail=1; fi
  }
  poison_rss c "C 14 (a finished coroutine's record is never freed)" 's/ __lang_coro_drop_slot(z); free(z); }$/ __lang_coro_drop_slot(z); }/'
  poison_rss c "C 8 (the saved state is never freed)" 's/ free(z->x); z->x = NULL; __lang_coro_drop_slot(z); free(z); }$/ __lang_coro_drop_slot(z); }/'
  poison_rss ll "LLVM 8 (the saved state is never freed)" '/^  call void @free(ptr %zx)$/d'
  poison_rss ll "LLVM 14 (a finished coroutine's record is never freed)" '/^  call void @free(ptr %z)$/d'
  # v0.1.623: RISC-V. The runtime is prelude text, so the poison edits what
  # `mere --rv-prelude` prints and the fixture is built with it (RV64).
  rv_poison() {  # $1 = label, $2 = sed expression, $3... = fixtures that must go red
    label="$1"; ex="$2"; shift 2
    [ "$have_rv" = 1 ] || { printf '  SKIP  %s\n' "POISON $label (no MEMU)"; return; }
    "$MERE" --rv-prelude > "$T/rv/prelude.mere"
    sed "$ex" "$T/rv/prelude.mere" > "$T/rv/poisoned.mere"
    if cmp -s "$T/rv/prelude.mere" "$T/rv/poisoned.mere"; then
      printf '  FAIL  %s\n' "POISON $label: the prelude no longer has the shape this poison removes"; pfail=1; return
    fi
    for f in "$@"; do
      want=$(printf '%s\n' "$RV_CASES" | while IFS='|' read -r g b w rc; do [ "$g" = "$f" ] && printf '%s' "$w"; done)
      got=$(MERE_RV_PRELUDE_FILE="$T/rv/poisoned.mere" run_rv "$f" 64)
      if [ "$got" != "$want" ]; then printf '  ok    %s\n' "POISON $label: $f goes red ([$got])"
      else printf '  FAIL  %s\n' "POISON $label: $f still green -- the fixture does not measure it"; pfail=1; fi
    done
  }
  rv_poison "RV 1 (the try_or record not carried)" 's/^  let _ = __rv_rtw_set 0 (__cget me 8) in$/  let _ = () in/' nested
  # The region depth and block marks are carried too, but leaving them shared
  # only makes protection more conservative (every open and close nests, so a
  # shared count is never 0 while some stack has a block open): no fixture can
  # go red without it, and none is claimed to.
  rv_poison "RV 3 (the high-water mark not raised at a switch)" 's/^    let _ = __rv_hwm_raise () in$/    let _ = () in/' region_cross
  rv_poison "RV 4 (no finished check)" 's/^  else (let st = __cget s 0 in if st == 3 || st == 4 then 0 - 1 else s);$/  else s;/' finished
  rv_poison "RV 5 (no hand-over check)" 's/^  if ns < 0 || ns == me then fail/  if ns < 0 then fail/' self_handoff
  rv_poison "RV 6 (blocks reused while a coroutine exists)" 's/^    let _ = __rv_rtw_set 47 (__rv_rtw 47 + 1) in$/    let _ = () in/' compact_reuse
  # v0.1.624: the release gives back only what no stopped stack reaches
  rv_poison "RV 9 (the release gives back a block a stopped stack reaches)" 's/^          let _ = (if vec_get pinned i == 0 then __rv_blk_free b$/          let _ = (if true then __rv_blk_free b/' compact_reuse
  # The saved registers are spilled before a scan of the running stack, but the
  # scan itself saves every register it uses on its own frame, so today the
  # spill is a backstop no fixture can tell apart; no poison is claimed for it.
  rv_poison "RV 8 (own region blocks not followed to the end)" 's/ \&\& (d < 3 || (v >= own \&\& v < own_hi))$/ \&\& d < 3/' scan
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then echo "coro --poison: ok (the gate can go red)"; else echo "coro --poison: FAILED"; pfail=1; fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "coro: ok"; else echo "coro: FAILED"; fi
exit "$fail"
