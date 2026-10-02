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
# hanging a probe loop or losing entries.
#
# v0.1.582: and the OWNER may not write a container another thread has read.
# The first foreign read marks it shared, and a shared container is read-only
# for good -- that is what stops the owner churning a Map under a reader. A
# table built once and only read is still shared freely (legit, legit_readonly).
#
#   param_vec / param_map / param_strbuf   must fail, naming the operation
#   param_reverse     vec_reverse writes too (unchecked up to v0.1.578)
#   param_versioned   a write in a loop range-check versioning made unchecked:
#                     the guard asks __vec_owned, the checked copy fails
#   shared_map_race / shared_vec_race   the owner writes under a reader: the
#                     owner's write fails, naming it (the sentence is SHARED's)
#   shared_phase      read by a thread, joined, then written by the owner:
#                     refused too (the documented cost of the rule)
#   shared_versioned  the thread reads in a versioned loop, whose unchecked
#                     reads leave no mark -- the guard's vec_len is the mark
#   ov_param          an OwnedVec reached through a closure a launcher spawns:
#                     nothing moved it, so the thread's use fails by name
#   ov_after_move     moved into a thread, then used by the spawner through a
#                     function: the second user fails by name
#   ov_moved          moved into a thread by spawn's closure: must print 3
#   legit                                  must run and print 31
#   legit_readonly    tables read by three threads: must print two sums
#
# --poison removes each check from the emitted C and LLVM, and the program it
# guards must then stop failing that way (the interpreter's check is not in
# emitted text).
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
SHSENT="another thread has read was written"
OVSENT="an OwnedVec belongs to one thread"
sentence_of() { case "$1" in shared_*) echo "$SHSENT" ;; ov_*) echo "$OVSENT" ;; *) echo "$SENT" ;; esac; }
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
    ov_moved) [ "$2" = 3 ] && [ "$3" = 0 ] && echo ok || echo "printed [$(echo "$2" | head -1 | cut -c1-60)] status $3, wanted 3" ;;
    legit) [ "$2" = 31 ] && [ "$3" = 0 ] && echo ok || echo "printed [$(echo "$2" | head -1)] status $3, wanted 31" ;;
    legit_readonly) [ "$2" = "4495530
1498500" ] && [ "$3" = 0 ] && echo ok || echo "printed [$(echo "$2" | tr '\n' ' ' | cut -c1-60)] status $3" ;;
    *) case "$2" in *"$(sentence_of "$1")"*) [ "$3" != 0 ] && echo ok || echo "said it but exited 0" ;;
         *) echo "did not fail by name: [$(echo "$2" | head -1 | cut -c1-60)] status $3" ;; esac ;;
  esac
}

for f in param_vec param_map param_strbuf param_reverse param_versioned \
         shared_map_race shared_vec_race shared_phase shared_versioned \
         ov_param ov_after_move ov_moved legit legit_readonly; do
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
  # a poison either removes a check (the race must then go through unnoticed)
  # or removes a hand-over (prog ov_moved: the legitimate move must then fail)
  while IFS='|' read -r prog be what expr; do
    [ -n "$be" ] || continue
    if ! why=$(build "$prog" "$be" "$expr"); then echo "  FAIL  POISON $be ($what): $why"; pf=1; continue; fi
    out=$(run "$T/bin"); st=$?
    case "$prog" in
      ov_moved)
        case "$out" in *"$OVSENT"*) echo "  ok    POISON $be ($what): the moved OwnedVec is refused" ;;
          *) echo "  FAIL  POISON $be ($what): the move still works -- the gate does not witness the hand-over"; pf=1 ;; esac ;;
      *)
        case "$out" in *"$(sentence_of "$prog")"*) echo "  FAIL  POISON $be ($what): still fails by name -- the gate does not witness the check"; pf=1 ;;
          *) echo "  ok    POISON $be ($what): the race goes through unnoticed" ;; esac ;;
    esac
  done <<'POISONS'
param_vec|c|the C check is gone|s/^#define __LANG_OWNED(c, k, o) .*/#define __LANG_OWNED(c, k, o) ((void)0)/
param_versioned|c|the versioning guard does not ask|s/^#define __LANG_OWNER_OK(c) .*/#define __LANG_OWNER_OK(c) 1/
param_vec|ll|the LLVM check is gone|/call void @__lang_owned(i32/d
param_reverse|ll|vec_reverse is not checked|/call void @__lang_owned(i32 .*@.own_vec_vec_reverse,/d
shared_phase|c|a read leaves no mark|s/^#define __LANG_READ(c) .*/#define __LANG_READ(c) ((void)0)/
shared_phase|c|the write does not say why|/if (owner == (__lang_tid() | __LANG_SHARED)) __lang_shared_fail(kind, op);/d
shared_versioned|c|the guard's vec_len leaves no mark|s/_len(mere_vec_int\* v) { __LANG_READ(v); return/_len(mere_vec_int* v) { return/
shared_phase|ll|a read leaves no mark|/call void @__lang_read_mark(ptr %__rd_p)/d
ov_param|c|OwnedVec use is not checked|s/^  __lang_ov_fail(op);$//
ov_moved|c|spawn does not give the OwnedVec away|s/(mu_g)->owner = 0; //
ov_param|ll|OwnedVec use is not checked|/call void @__lang_ov_use(ptr/d
ov_moved|ll|spawn does not give the OwnedVec away|/store atomic i32 0, ptr %t[0-9]* monotonic, align 4/d
shared_versioned|ll|the guard's vec_len leaves no mark|/^define i64 @mere_vec_int_len(/,/^}/{/call void @__lang_read_mark/d;}
POISONS
  [ "$pf" = 0 ] || { echo "owner_check --poison: FAILED"; exit 1; }
fi
[ "$fail" = 0 ] || { echo "owner_check: FAILED"; exit 1; }
if [ "${1:-}" = --poison ]; then echo "owner_check --poison: ok (the gate can go red)"; else echo "owner_check: ok"; fi
