#!/bin/sh
# scripts/exit_status_check.sh — `exit n` ends the program with n, on every backend.
#
# A program's status is part of its answer, and until v0.1.434 the Wasm backend
# threw it away: `exit` evaluated the code, dropped it, and executed
# `unreachable`, which every host reports as a trap. So `exit 0` -- a program
# saying it succeeded -- came back as 1, and so did `exit 3`.
#
# Nothing caught it. The parity suite compares stdout, and its failure section
# compares the status of programs that FAIL, where the diagnostic is the last
# line of output (Wasm) or the first line of stderr (the others). A program that
# exits with a status and no diagnostic fits neither: the failure section reads
# its last stdout line as a message and finds the outputs unequal, which is the
# harness's convention showing through rather than a divergence. Hence this
# gate, which compares only the number.
#
# It also would not have been caught by adding an `exit` to a parity program,
# because none of the 157 had one -- the whole builtin was outside what the
# differential suite ran.
#
# Cases: a status of 0 after output (the regression that mattered most, because
# it turns success into failure), a nonzero status (a backend that ignores the
# code and ends cleanly fails here), and a program that ends without `exit`
# (so the check has a negative: it must not report 7 for everything).
#
# Backends: interp, C, LLVM, Wasm. Component mode still traps on exit (its env
# host imports are dropped and routing through wasi proc_exit is Q-114's second
# half), which is why --component is not in this table.
#
# Usage:
#   sh scripts/exit_status_check.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}

if [ ! -x "$MERE" ]; then
  echo "exit_status_check: $MERE not found — run dune build first" >&2
  exit 1
fi

CC=$(command -v clang || command -v cc || true)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
checked=0

run_case() {
  name=$1; src=$2; want=$3
  printf '%s\n' "$src" > "$TMP/$name.mere"

  "$MERE" "$TMP/$name.mere" >"$TMP/$name.interp.out" 2>&1
  irc=$?
  if [ "$irc" != "$want" ]; then
    echo "FAIL $name: interp exited $irc, expected $want"; fail=1
  fi
  checked=$((checked + 1))

  if [ -n "$CC" ]; then
    if "$MERE" -c "$TMP/$name.mere" > "$TMP/$name.c" 2>/dev/null &&
       $CC -O1 -w "$TMP/$name.c" -o "$TMP/$name.cbin" 2>/dev/null; then
      "$TMP/$name.cbin" >/dev/null 2>&1; crc=$?
      [ "$crc" = "$want" ] || { echo "FAIL $name: C exited $crc, expected $want"; fail=1; }
      checked=$((checked + 1))
    else
      echo "FAIL $name: C backend did not build"; fail=1
    fi

    if "$MERE" -ll "$TMP/$name.mere" > "$TMP/$name.ll" 2>/dev/null &&
       $CC -O1 -w "$TMP/$name.ll" -o "$TMP/$name.llbin" 2>/dev/null; then
      "$TMP/$name.llbin" >/dev/null 2>&1; lrc=$?
      [ "$lrc" = "$want" ] || { echo "FAIL $name: LLVM exited $lrc, expected $want"; fail=1; }
      checked=$((checked + 1))
    else
      echo "SKIP $name: LLVM backend did not build (refusal or no clang)"
    fi
  fi

  if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
    if "$MERE" -w "$TMP/$name.mere" > "$TMP/$name.wat" 2>/dev/null &&
       wat2wasm --enable-tail-call "$TMP/$name.wat" -o "$TMP/$name.wasm" 2>/dev/null; then
      node "$ROOT/scripts/run_wasm.js" "$TMP/$name.wasm" >/dev/null 2>&1; wrc=$?
      [ "$wrc" = "$want" ] || { echo "FAIL $name: Wasm exited $wrc, expected $want"; fail=1; }
      checked=$((checked + 1))
    else
      echo "FAIL $name: Wasm backend did not build"; fail=1
    fi
  fi
}

run_case exit_zero    'let _ = print "before" in exit 0'      0
run_case exit_nonzero 'let _ = print "before" in exit 7'      7
run_case no_exit      'print "before"'                        0

# A gate that checked nothing would print the same success line as one that
# checked everything (a skipped toolchain is how that happens), so the count is
# part of the verdict.
if [ "$checked" -lt 6 ]; then
  echo "FAIL exit_status_check: only $checked backend runs happened — a toolchain is missing and this gate is not measuring what it claims"
  exit 1
fi

if [ "$fail" = 0 ]; then
  echo "PASS exit_status_check: $checked backend runs, exit codes agree"
  exit 0
fi
exit 1
