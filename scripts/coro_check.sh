#!/bin/sh
# scripts/coro_check.sh — same-thread coroutines (coro_new / coro_switch / coro_self).
#
# A coroutine is a second stack on the thread that made it. Swapping the
# registers is the easy part; what a switch must ALSO carry is every piece of
# runtime state that belongs to a stack rather than to a thread. On the C
# backend that is four things -- the current region, the live-block stack
# (what a fail unwinds), the innermost try_or's jmpbuf, and the stack bounds the
# SIGSEGV handler compares a fault against. Leave any one on the thread and the
# program reads freed memory, releases another stack's blocks, longjmps onto a
# stack that is not running, or calls its own overflow a segfault.
#
# WHAT IS CHECKED: every fixture in test/coro/ gives its expected first lines
# and exit status, on the interpreter and on C (at -O0 and -O2). The overflow
# fixture is C only: whether that recursion fits is a fact about the default
# stack size, and the interpreter's stack is not a native one.
#
# THE REFUSALS: a body that captures a block's container is a type error (its
# env is copied out of the block, and a container's copy is the same handle);
# a Coro cannot be sent or captured across a thread; Wasm and RV name the
# builtin and the reason.
#
# --poison: the emitted C is edited to drop one carried piece (or one check) at
# a time, and the fixture that exists for it must go red. A fixture that stays
# green without the fix is not measuring it.
#
# Usage:
#   sh scripts/coro_check.sh            # check
#   sh scripts/coro_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "coro: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "coro: no C compiler — skipping"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MODE="${1:-}"
LIMIT="${LIMIT:-60}"
FX="$ROOT/test/coro"
fail=0

# fixture | backends | expected output (lines joined with ;) | exit
CASES='region|ic|B: my string survived;4106|0
fail|ic|fail: from the coroutine|1
nested|ic|main caught: -1;B caught: 5;main: done|0
unwind|ic|B: region R2 survived main'"'"'s unwind;4096|0
env|ic|env: intact;8192|0
finished|ic|B: ran;switch to a finished coroutine: refused|0
self_handoff|ic|coro: a finished coroutine must hand over to another live coroutine|1
many|ic|10000|0
pingpong|ic|1000000|0
overflow|c|stack overflow (recursion too deep)|1
deep/deep|c|2000001000000;main: back|0'

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

build() {  # $1 = fixture, $2 = opt, [$3 = sed expression] -> $T/bin, or prints why not
  "$MERE" -c "$FX/$1.mere" > "$T/g.c" 2>"$T/emit.err" || { echo "EMITFAIL $(head -1 "$T/emit.err")"; return 1; }
  if [ -n "${3:-}" ]; then
    sed "$3" "$T/g.c" > "$T/p.c"
    if cmp -s "$T/p.c" "$T/g.c"; then echo "SEDNOMATCH"; return 1; fi
    mv "$T/p.c" "$T/g.c"
  fi
  "$CC" "$2" -w -o "$T/bin" "$T/g.c" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(head -1 "$T/cc.err")"; return 1; }
}

want_of() {  # $1 = fixture -> "expected|exit"
  printf '%s\n' "$CASES" | while IFS='|' read -r f b w rc; do
    [ "$f" = "$1" ] && printf '%s|%s' "$w" "$rc"
  done
}

printf '%s\n' "$CASES" > "$T/cases"
while IFS='|' read -r f b w rc; do
  case "$b" in *i*)
    got=$(run_bounded "$MERE" "$FX/$f.mere")
    if [ "$got" = "$w|$rc" ]; then printf '  ok    %s\n' "interp $f"
    else printf '  FAIL  %s\n' "interp $f: got [$got] wanted [$w|$rc]"; fail=1; fi ;;
  esac
  for opt in -O0 -O2; do
    if ! why=$(build "$f" "$opt"); then printf '  FAIL  %s\n' "C $opt $f: $why"; fail=1; continue; fi
    got=$(run_bounded "$T/bin")
    if [ "$got" = "$w|$rc" ]; then printf '  ok    %s\n' "C $opt $f"
    else printf '  FAIL  %s\n' "C $opt $f: got [$got] wanted [$w|$rc]"; fail=1; fi
  done
done < "$T/cases"

# --- refusals -------------------------------------------------------------
refuse() {  # $1 = label, $2 = flag ("" = interpreter), $3 = program, $4 = text the refusal must contain
  printf '%s\n' "$3" > "$T/r.mere"
  if [ -n "$2" ]; then "$MERE" "$2" "$T/r.mere" > /dev/null 2> "$T/r.err"; rc=$?
  else "$MERE" "$T/r.mere" > /dev/null 2> "$T/r.err"; rc=$?; fi
  if [ "$rc" != 0 ] && grep -qF -- "$4" "$T/r.err"; then printf '  ok    %s\n' "refused: $1"
  else printf '  FAIL  %s\n' "not refused: $1 (exit $rc: $(head -1 "$T/r.err"))"; fail=1; fi
}
refuse "a body capturing a block's Vec" "" 'let root = coro_self ();
let c = region R { let v = vec_new () in let _ = vec_push v 1 in coro_new (fn () -> let _ = print_int (vec_len v) in root) };
coro_switch c' 'coro_new: the body captures `v`'
refuse "a body capturing a block's Vec (C)" -c 'let root = coro_self ();
let c = region R { let v = vec_new () in let _ = vec_push v 1 in coro_new (fn () -> let _ = print_int (vec_len v) in root) };
coro_switch c' 'coro_new: the body captures `v`'
refuse "a Coro sent over a channel" "" 'let ch = channel_new ();
let _ = channel_send ch (coro_self ());
0' '`Coro` is not Send'
refuse "a Coro captured by spawn" "" 'let c = coro_self ();
let h = spawn (fn () -> coro_switch c);
join h' 'cannot capture `c` : Coro across a thread boundary'
refuse "Wasm names it" -w 'coro_switch (coro_self ())' 'is not available on Wasm'
refuse "RV32I names it" -rv 'coro_switch (coro_self ())' 'is unsupported on this target'
refuse "RV64 names it" -rv64 'coro_switch (coro_self ())' 'is unsupported on this target'

# and what must NOT be refused: a block's VALUE is copied out with the env
printf '%s\n' 'let root = coro_self ();
let c = region R { let s = str_repeat "x" 3 in coro_new (fn () -> let _ = print s in root) };
let _ = region Z { str_len (str_repeat "Z" 4096) };
coro_switch c' > "$T/ok.mere"
got=$("$MERE" -c "$T/ok.mere" 2>&1 > "$T/ok.c") || true
if "$CC" -w -o "$T/ok" "$T/ok.c" -lm -lpthread 2>/dev/null && [ "$("$T/ok")" = "xxx" ]; then
  printf '  ok    %s\n' "allowed: a body capturing a block's str (copied with the env)"
else
  printf '  FAIL  %s\n' "a body capturing a block's str: $got"; fail=1
fi

if [ "$MODE" = "--poison" ]; then
  pfail=0
  poison() {  # $1 = label, $2 = sed expression, $3... = fixtures that must go red
    label="$1"; ex="$2"; shift 2
    for f in "$@"; do
      if ! why=$(build "$f" -O2 "$ex"); then
        printf '  FAIL  %s\n' "POISON $label: $f: $why -- the runtime no longer has the shape this poison removes"
        pfail=1; continue
      fi
      got=$(run_bounded "$T/bin")
      w=$(want_of "$f")
      if [ "$got" = "$w" ]; then
        printf '  FAIL  %s\n' "POISON $label: $f still green without it"
        pfail=1
      else
        printf '  ok    %s\n' "POISON $label: $f goes red ([$got])"
      fi
    done
  }
  poison "1 (current region not carried)" '/^  __lang_current_region = to->s_cur;$/d' region
  poison "2 (live-block stack not carried)" '/^  __lang_region_active = to->s_active; __lang_region_active_n = to->s_active_n;$/d' unwind
  poison "3 (try_or jmpbuf not carried)" '/^  __lang_fail_jmpbuf_set = to->s_jb_set;$/d' fail nested
  poison "4 (stack bounds not carried)" '/^  __lang_stack_lo = to->s_lo; __lang_stack_hi = to->s_hi;$/d' overflow
  poison "5 (env left in the block)" 's/^    if (h->__r != &__lang_default_region \&\& h->__copy)$/    if (0)/' env
  poison "6 (no finished check)" '/^  if (to->state == 3) __lang_fail_impl/d' finished
  poison "7 (no hand-over check)" 's/^  if (!next || next == self || next->state == 3)$/  if (!next)/' self_handoff
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then echo "coro --poison: ok (the gate can go red)"; else echo "coro --poison: FAILED"; pfail=1; fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "coro: ok"; else echo "coro: FAILED"; fi
exit "$fail"
