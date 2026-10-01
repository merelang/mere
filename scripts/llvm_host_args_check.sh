#!/bin/sh
# scripts/llvm_host_args_check.sh -- two host-facing corners of the LLVM backend
# that no gate built and ran, both found by mwasm the first time anything
# compiled its IR (downstream_cc_check, v0.1.571):
#
#   file_only   a program whose only file builtins are file_openrw / file_size /
#               file_close must BUILD: they pull in a runtime block that calls
#               the Vec[int] helpers, which were emitted only for programs with a
#               Vec[int] of their own
#   args_len    `args ()` strings must be strs: their length right and `++` with
#               them fine -- they were argv's raw pointers, with no length header
#
# Each is run on the interpreter (the answer), C and LLVM, and must agree.
# --poison undoes each fix in the emitted IR and the program must go red.
#
# Usage: sh scripts/llvm_host_args_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "llvm_host_args: $MERE not built" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "llvm_host_args: no clang (LLVM IR needs it)" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FX="$ROOT/test/llvmhost"
ARGS="hello wörld x"
fail=0

run() { perl -e 'alarm 20; exec @ARGV' "$@" 2>&1; }

# $1 program, $2 c|ll, [$3 perl substitution] -> $T/bin or prints why not
build() {
  "$MERE" "-$2" "$FX/$1.mere" > "$T/g.$2" 2>"$T/e" || { echo "EMITFAIL $(head -1 "$T/e")"; return 1; }
  if [ -n "${3:-}" ]; then
    perl -pe "$3" "$T/g.$2" > "$T/p.$2"
    cmp -s "$T/p.$2" "$T/g.$2" && { echo "SEDNOMATCH"; return 1; }
    mv "$T/p.$2" "$T/g.$2"
  fi
  if [ "$2" = c ]; then "$CC" -w -o "$T/bin" "$T/g.c" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(head -1 "$T/cc.err")"; return 1; }
  else clang -w -x ir -o "$T/bin" "$T/g.ll" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(grep -m1 error "$T/cc.err")"; return 1; }
  fi
}

for f in file_only args_len; do
  # shellcheck disable=SC2086
  want=$(run "$MERE" "$FX/$f.mere" $ARGS)
  [ -n "$want" ] || { echo "  FAIL  interp $f printed nothing"; fail=1; continue; }
  for be in c ll; do
    if ! why=$(build "$f" "$be"); then echo "  FAIL  $be $f: $why"; fail=1; continue; fi
    # shellcheck disable=SC2086
    got=$(run "$T/bin" $ARGS)
    if [ "$got" = "$want" ]; then echo "  ok    $be $f"
    else echo "  FAIL  $be $f: got [$(echo "$got" | head -1 | cut -c1-60)] wanted [$(echo "$want" | head -1 | cut -c1-60)]"; fail=1; fi
  done
done

if [ "${1:-}" = --poison ]; then
  pf=0
  # program | what it undoes | perl substitution on the IR
  while IFS='|' read -r f what expr; do
    [ -n "$f" ] || continue
    # shellcheck disable=SC2086
    want=$(run "$MERE" "$FX/$f.mere" $ARGS)
    if why=$(build "$f" ll "$expr"); then
      # shellcheck disable=SC2086
      got=$(run "$T/bin" $ARGS)
      if [ "$got" = "$want" ]; then echo "  FAIL  POISON ll $f ($what): still green"; pf=1
      else echo "  ok    POISON ll $f ($what): goes red"; fi
    else
      case "$why" in
        CCFAIL*) echo "  ok    POISON ll $f ($what): goes red -- $why" ;;
        *) echo "  FAIL  POISON ll $f ($what): $why"; pf=1 ;;
      esac
    fi
  done <<'POISONS'
file_only|the Vec[int] helpers are not emitted|s/^define (\S+ )?\@mere_vec_int_get\(/define $1\@mere_vec_int_get_gone(/
args_len|an argument is argv's pointer again|s/^  %s = call ptr \@__lang_str_alloc_in\(ptr \@__lang_default_region, i64 %n\)$/  %s = getelementptr i8, ptr %raw, i64 0/
POISONS
  [ "$pf" = 0 ] || { echo "llvm_host_args --poison: FAILED"; exit 1; }
fi
[ "$fail" = 0 ] || { echo "llvm_host_args: FAILED"; exit 1; }
if [ "${1:-}" = --poison ]; then echo "llvm_host_args --poison: ok (the gate can go red)"; else echo "llvm_host_args: ok"; fi
