#!/bin/sh
# scripts/threads_alloc_check.sh — two threads allocating at once, on C and LLVM.
#
# Q-180. The LLVM backend's allocator took no lock on the default region (C's
# does), and its current region and active-region stack were process globals
# (C's are thread-local). Two spawned threads building strings at the same
# time -- nothing shared between them -- died with `out of memory` in 5 runs
# of 5; inside `region R { }` blocks they hung or ran out of memory. One
# thread alone was fine, which is why no gate saw it: none ran two allocating
# threads concurrently on LLVM.
#
# WHAT IS CHECKED: both fixtures (test/threadalloc/) answer `bad: 0 0` on C
# and on LLVM, three runs each, each under a time bound.
#
# --poison: the LLVM IR is emitted, then the fix is taken out again with sed
# -- (1) the calls that take the default-region lock, (2) `thread_local` on
# the current-region word -- and each must turn a fixture red. A fixture that
# stays green without the fix is not measuring the fix.
#
# Usage:
#   sh scripts/threads_alloc_check.sh            # check
#   sh scripts/threads_alloc_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "threads_alloc: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || { echo "threads_alloc: no clang — LLVM IR cannot be compiled here, skipping"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MODE="${1:-}"
fail=0
RUNS="${RUNS:-3}"
LIMIT="${LIMIT:-30}"

run_bounded() {  # $1 = binary -> first line of output, or TIMEOUT
  perl -e 'alarm shift; exec @ARGV' "$LIMIT" "$1" > "$T/out" 2>&1
  rc=$?
  if [ "$rc" = 142 ]; then echo "TIMEOUT"; else tail -1 "$T/out"; fi
}

check_bin() {  # $1 = label, $2 = binary -> 0 if every run says bad: 0 0
  ok=1
  i=0
  while [ "$i" -lt "$RUNS" ]; do
    got=$(run_bounded "$2")
    [ "$got" = "bad: 0 0" ] || { ok=0; last="$got"; }
    i=$((i + 1))
  done
  if [ "$ok" = 1 ]; then return 0; fi
  echo "$last" > "$T/last"
  return 1
}

for fx in default_region block_region; do
  src="$ROOT/test/threadalloc/$fx.mere"
  for flag in -c -ll; do
    b=C; ext=c; [ "$flag" = "-ll" ] && { b=LLVM; ext=ll; }
    "$MERE" "$flag" "$src" > "$T/$fx.$ext" 2>"$T/emit.err" || { printf '  FAIL  %s\n' "$b $fx: emit failed: $(head -1 "$T/emit.err")"; fail=1; continue; }
    "$CC" -O0 -w -o "$T/$fx.$ext.bin" "$T/$fx.$ext" -lpthread 2>"$T/cc.err" || { printf '  FAIL  %s\n' "$b $fx: $CC refused it: $(head -1 "$T/cc.err")"; fail=1; continue; }
    if check_bin "$b $fx" "$T/$fx.$ext.bin"; then
      printf '  ok    %s\n' "$b $fx: two threads allocating at once, $RUNS runs, bad: 0 0"
    else
      printf '  FAIL  %s\n' "$b $fx: a run answered '$(cat "$T/last")'"
      fail=1
    fi
  done
done

if [ "$MODE" = "--poison" ]; then
  pfail=0
  poison() {  # $1 = label, $2 = sed expression, $3 = fixture
    sed "$2" "$T/$3.ll" > "$T/p.ll"
    if cmp -s "$T/p.ll" "$T/$3.ll"; then
      printf '  FAIL  %s\n' "POISON $1: the sed matched nothing -- the IR no longer has the shape this poison removes"
      pfail=1; return
    fi
    "$CC" -O0 -w -o "$T/p.bin" "$T/p.ll" -lpthread 2>/dev/null || { printf '  FAIL  %s\n' "POISON $1: did not compile"; pfail=1; return; }
    if check_bin "poison" "$T/p.bin"; then
      printf '  FAIL  %s\n' "POISON $1: still green without the fix -- $3 is not measuring it"
      pfail=1
    else
      printf '  ok    %s\n' "POISON $1: $3 goes red ('$(cat "$T/last")')"
    fi
  }
  poison "1 (no default-region lock)" 's/^  call void @__lang_rlock()$//; s/^  call void @__lang_runlock()$//' default_region
  poison "2 (current region shared by the threads)" 's/^@__lang_current_region = internal thread_local global/@__lang_current_region = internal global/' block_region
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then echo "threads_alloc --poison: ok (the gate can go red)"; else echo "threads_alloc --poison: FAILED"; pfail=1; fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "threads_alloc: ok"; else echo "threads_alloc: FAILED"; fi
exit "$fail"
