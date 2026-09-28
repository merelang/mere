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
command -v "$CC" >/dev/null 2>&1 || { echo "coro: no C compiler — skipping"; exit 0; }
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
deep/deep|cl|2000001000000;main: back|0'

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
# A million made and finished must stay small: the handle's record is never
# freed (a finished coroutine is still a value), so everything else in it has
# to be. 128 MiB is about four times what a correct run holds (34 MiB on macOS)
# and a third of what one holding a jmp_buf per coroutine does.
RSS_CAP=134217728
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
  elif [ "$r" -lt "$RSS_CAP" ]; then printf '  ok    %s\n' "$name: a million finished coroutines hold $((r / 1048576)) MiB"
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
  poison c "C 5 (env left in the block)" 's/^    if (h->__r != &__lang_default_region \&\& h->__copy)$/    if (0)/' env
  poison c "C 6 (no finished check)" '/^  if (to->state == 3) __lang_fail_impl/d' finished
  poison c "C 7 (no hand-over check)" 's/^  if (!next || next == self || next->state == 3)$/  if (!next)/' self_handoff
  poison ll "LLVM 1 (current region not carried)" '/^  store ptr %tr, ptr @__lang_current_region$/d' region
  poison ll "LLVM 2 (live-block stack not carried)" '/^  store ptr %ta, ptr @__lang_region_active$/d' unwind
  poison ll "LLVM 3 (try_or jmpbuf not carried)" '/^  store i32 %tjs, ptr @__lang_fail_jmpbuf_set$/d' fail nested
  poison ll "LLVM 4 (stack bounds not carried)" '/^  store i64 %tlo, ptr @__lang_stack_lo$/d; /^  store i64 %thi, ptr @__lang_stack_hi$/d' overflow
  poison ll "LLVM 5 (a block's coroutine not refused)" 's/^  br i1 %inblock, label %refuse, label %alloc$/  br label %alloc/' env
  poison ll "LLVM 6 (no finished check)" 's/^  br i1 %dead, label %finished, label %self$/  br label %self/' finished
  poison ll "LLVM 7 (no hand-over check)" 's/^  br i1 %bad0, label %nowhere, label %chk$/  br label %chk/' self_handoff
  poison_rss() {  # $1 = c|ll, $2 = label, $3 = sed expression
    if ! why=$(build million -O2 "$1" "$3"); then
      printf '  FAIL  %s\n' "POISON $2: $why -- the runtime no longer has the shape this poison removes"; pfail=1; return
    fi
    r=$(rss_of "$T/bin")
    if [ -z "$r" ]; then printf '  FAIL  %s\n' "POISON $2: no /usr/bin/time here, so the question was not asked"; pfail=1
    elif [ "$r" -ge "$RSS_CAP" ]; then printf '  ok    %s\n' "POISON $2: million goes red ($((r / 1048576)) MiB)"
    else printf '  FAIL  %s\n' "POISON $2: million still under the cap without it ($((r / 1048576)) MiB)"; pfail=1; fi
  }
  poison_rss c "C 8 (the saved state is never freed)" 's/ free(z->x); z->x = NULL; }$/ }/'
  poison_rss ll "LLVM 8 (the saved state is never freed)" '/^  call void @free(ptr %zx)$/d'
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then echo "coro --poison: ok (the gate can go red)"; else echo "coro --poison: FAILED"; pfail=1; fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "coro: ok"; else echo "coro: FAILED"; fi
exit "$fail"
