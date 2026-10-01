#!/bin/sh
# scripts/region_uaf_check.sh -- a value that outlives the block it was made in,
# by a route the types do not see, must still be there when it is read.
#
# WHY A SECOND GATE NEXT TO escape_check. escape_check runs test/escape/ROUTES
# and compares VERDICTS: does each backend accept or refuse the program. A SAFE
# row is accepted, and nothing there asks whether the accepted program then
# reads the right bytes. Four routes were accepted, safe by every verdict, and
# use-after-free at run time:
#
#   kept_then_written    (Q-190, v0.1.563) a container retained by v0.1.557 and
#                        WRITTEN after its block -- the block's struct was
#                        recycled, so the writes went into the next block
#   spawn_env_in_block   (Q-191, v0.1.564) a thread handed its closure's env as
#                        it was, read after the block was reused
#   ownedvec_store       (Q-192, v0.1.564) owned_vec_push stored a str as the
#                        pointer it was
#   channel_from_block   (v0.1.564, LLVM) a message sent as the pointer it was
#
# plus coro_env_from_block, which was right already (v0.1.558) and is here so
# that it stays right.
#
# So this gate RUNS each program, after making the block's memory be reused (the
# churn in each program), on the interpreter -- which has no arenas and is the
# answer -- and on C and LLVM, and requires the same output. The v0.1.557
# witness for Q-188 only READ the escaped value afterwards, which is why Q-190
# survived it: a lifetime fix has to be witnessed by a write, too.
#
# --poison undoes each fix in the emitted code, one at a time, and the program
# that exists for it must go red.
#
# Usage: sh scripts/region_uaf_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "region_uaf: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "region_uaf: no C compiler" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FX="$ROOT/test/uaf"
MODE="${1:-}"
fail=0

# program | backends (c C, l LLVM)
CASES='kept_then_written|cl
spawn_env_in_block|c
ownedvec_store|cl
channel_from_block|cl
coro_env_from_block|c'

run_bin() { perl -e 'alarm 20; exec @ARGV' "$1" 2>&1; }

build() {  # $1 = program, $2 = c|ll, [$3 = sed expression] -> $T/bin, or prints why not
  "$MERE" "-$2" "$FX/$1.mere" > "$T/g.$2" 2>"$T/emit.err" || { echo "EMITFAIL $(head -1 "$T/emit.err")"; return 1; }
  if [ -n "${3:-}" ]; then
    sed "$3" "$T/g.$2" > "$T/p.$2"
    if cmp -s "$T/p.$2" "$T/g.$2"; then echo "SEDNOMATCH"; return 1; fi
    mv "$T/p.$2" "$T/g.$2"
  fi
  if [ "$2" = c ]; then lang=c; else lang=ir; fi
  "$CC" -w -x "$lang" -o "$T/bin" "$T/g.$2" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(head -1 "$T/cc.err")"; return 1; }
}

printf '%s\n' "$CASES" | while IFS='|' read -r f b; do
  want=$("$MERE" "$FX/$f.mere" 2>&1)
  case "$want" in
    *ZZZZ*|"") printf '  FAIL  %s\n' "interp $f: the answer itself looks wrong: $want"; echo x >> "$T/failed"; continue ;;
  esac
  for be in c ll; do
    case "$be" in c) letter=c; name=C ;; ll) letter=l; name=LLVM ;; esac
    case "$b" in *"$letter"*) ;; *) continue ;; esac
    if ! why=$(build "$f" "$be"); then printf '  FAIL  %s\n' "$name $f: $why"; echo x >> "$T/failed"; continue; fi
    got=$(run_bin "$T/bin")
    if [ "$got" = "$want" ]; then printf '  ok    %s\n' "$name $f"
    else printf '  FAIL  %s\n' "$name $f: got [$(echo "$got" | head -1 | cut -c1-40)] wanted [$(echo "$want" | head -1 | cut -c1-40)]"; echo x >> "$T/failed"; fi
  done
done
[ -f "$T/failed" ] && fail=1

if [ "$MODE" = --poison ]; then
  # program | backend | what the poison undoes | sed expression
  POISONS='kept_then_written|c|a kept struct is recycled again|s/    r->fwd = t;//
kept_then_written|ll|a kept struct is freed again|s/  br i1 %none, label %freestruct, label %leave/  br label %freestruct/
spawn_env_in_block|c|the thread gets the env as it was|s/__se = __sh->__copy(&__lang_default_region, __se);/(void)0;/
ownedvec_store|c|owned_vec_push stores the pointer|s/v->data\[v->len++\] = __mcopy_str(&__lang_default_region, x);/v->data[v->len++] = x;/
ownedvec_store|ll|owned_vec_push stores the pointer|s/= call ptr @__mcopy_str(ptr @__lang_default_region, ptr \(%t[0-9]*\))/= getelementptr i8, ptr \1, i64 0/
channel_from_block|ll|the message is sent as the pointer|s/= call ptr @__mcopy_str(ptr @__lang_default_region, ptr \(%t[0-9]*\))/= getelementptr i8, ptr \1, i64 0/'
  printf '%s\n' "$POISONS" | while IFS='|' read -r f be what expr; do
    want=$("$MERE" "$FX/$f.mere" 2>&1)
    if ! why=$(build "$f" "$be" "$expr"); then printf '  FAIL  %s\n' "POISON $be $f ($what): $why"; echo x >> "$T/pfailed"; continue; fi
    got=$(run_bin "$T/bin")
    if [ "$got" != "$want" ]; then printf '  ok    %s\n' "POISON $be $f ($what): goes red"
    else printf '  FAIL  %s\n' "POISON $be $f ($what): still green -- the program does not witness the fix"; echo x >> "$T/pfailed"; fi
  done
  [ -f "$T/pfailed" ] && { echo "region_uaf --poison: FAILED"; exit 1; }
fi

if [ "$fail" != 0 ]; then echo "region_uaf: FAILED"; exit 1; fi
if [ "$MODE" = --poison ]; then echo "region_uaf --poison: ok (the gate can go red)"; else echo "region_uaf: ok"; fi
