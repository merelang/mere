#!/bin/sh
# scripts/owner_check.sh -- a container written by a thread other than the one
# that made it fails by name, on the interpreter, C and LLVM (v0.1.575).
#
# The type check (v0.1.574) follows what a spawned thread reaches through
# functions whose definitions it can see. A closure that arrives as a PARAMETER
# is not one of them -- a library that spawns the handler it was given cannot
# see what the handler touches -- and mere-blog's ledger race was exactly that.
# So Map, Vec, StrBuf, ByteBuf and ListBuf record the thread that made them, and
# a write from any other thread stops the program with one sentence instead of
# hanging a probe loop or losing entries. Reads are not checked: a table built
# once and only read is shared safely (test/owner/legit.mere does that).
#
#   param_vec / param_map / param_strbuf   must fail, naming the operation
#   param_reverse     vec_reverse writes too (unchecked up to v0.1.578)
#   param_versioned   a write in a loop range-check versioning made unchecked:
#                     the guard asks __vec_owned, the checked copy fails
#   legit                                  must run and print 31
#
# --poison removes the check from the emitted C and LLVM, and the races must
# then stop failing (the interpreter's check is not in emitted text).
#
# Usage: sh scripts/owner_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "owner_check: $MERE not built" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "owner_check: no clang (LLVM IR needs it)" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FX="$ROOT/test/owner"
SENT="made by one thread was written by another"
fail=0

run() { perl -e 'alarm 20; exec @ARGV' "$@" 2>&1; }

# $1 program, $2 c|ll, [$3 sed expression] -> $T/bin or prints why not
build() {
  "$MERE" "-$2" "$FX/$1.mere" > "$T/g.$2" 2>"$T/e" || { echo "EMITFAIL $(head -1 "$T/e")"; return 1; }
  if [ -n "${3:-}" ]; then
    sed "$3" "$T/g.$2" > "$T/p.$2"
    cmp -s "$T/p.$2" "$T/g.$2" && { echo "SEDNOMATCH"; return 1; }
    mv "$T/p.$2" "$T/g.$2"
  fi
  if [ "$2" = c ]; then "$CC" -w -o "$T/bin" "$T/g.c" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(head -1 "$T/cc.err")"; return 1; }
  else clang -w -x ir -o "$T/bin" "$T/g.ll" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(grep -m1 error "$T/cc.err")"; return 1; }
  fi
}

judge() {  # $1 program, $2 output, $3 status -> ok or why not
  case "$1" in
    legit) [ "$2" = 31 ] && [ "$3" = 0 ] && echo ok || echo "printed [$(echo "$2" | head -1)] status $3, wanted 31" ;;
    *) case "$2" in *"$SENT"*) [ "$3" != 0 ] && echo ok || echo "said it but exited 0" ;;
         *) echo "did not fail by name: [$(echo "$2" | head -1 | cut -c1-60)] status $3" ;; esac ;;
  esac
}

for f in param_vec param_map param_strbuf param_reverse param_versioned legit; do
  out=$(run "$MERE" "$FX/$f.mere"); st=$?
  v=$(judge "$f" "$out" "$st"); [ "$v" = ok ] && echo "  ok    interp $f" || { echo "  FAIL  interp $f: $v"; fail=1; }
  for be in c ll; do
    if ! why=$(build "$f" "$be"); then echo "  FAIL  $be $f: $why"; fail=1; continue; fi
    out=$(run "$T/bin"); st=$?
    v=$(judge "$f" "$out" "$st"); [ "$v" = ok ] && echo "  ok    $be $f" || { echo "  FAIL  $be $f: $v"; fail=1; }
  done
done

if [ "${1:-}" = --poison ]; then
  pf=0
  while IFS='|' read -r prog be what expr; do
    [ -n "$be" ] || continue
    if ! why=$(build "$prog" "$be" "$expr"); then echo "  FAIL  POISON $be ($what): $why"; pf=1; continue; fi
    out=$(run "$T/bin"); st=$?
    case "$out" in *"$SENT"*) echo "  FAIL  POISON $be ($what): still fails by name -- the gate does not witness the check"; pf=1 ;;
      *) echo "  ok    POISON $be ($what): the race goes through unnoticed" ;; esac
  done <<'POISONS'
param_vec|c|the C check is gone|s/^#define __LANG_OWNED(c, k, o) .*/#define __LANG_OWNED(c, k, o) ((void)0)/
param_versioned|c|the versioning guard does not ask|s/^#define __LANG_OWNER_OK(c) .*/#define __LANG_OWNER_OK(c) 1/
param_vec|ll|the LLVM check is gone|/call void @__lang_owned(i32/d
param_reverse|ll|vec_reverse is not checked|/@.own_vec_vec_reverse)$/d
POISONS
  [ "$pf" = 0 ] || { echo "owner_check --poison: FAILED"; exit 1; }
fi
[ "$fail" = 0 ] || { echo "owner_check: FAILED"; exit 1; }
if [ "${1:-}" = --poison ]; then echo "owner_check --poison: ok (the gate can go red)"; else echo "owner_check: ok"; fi
