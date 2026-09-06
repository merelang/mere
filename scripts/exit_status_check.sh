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
# Backends: interp, C, LLVM, Wasm, and -- when the toolchain is present -- a
# command component through wasi.
#
# THE COMPONENT LEG ASSERTS A DIFFERENT THING ON PURPOSE. A command component
# ends through `wasi:cli/exit`, whose signature is `exit: func(status: result)`:
# success or failure, with no number in it. So `exit 0` gives 0 and `exit 7`
# gives 1, and the 1 is the interface's limit rather than this compiler's. The
# leg pins both, because "exit 7 gives 1" is only acceptable while the reason
# is written down next to it -- and if a future wasi carries a status, this is
# where that shows up as a red gate.
#
# A reactor component still traps: it has no adapter and no process to end.
# And a program whose main expression IS the exit (`... in exit 7`, whose type
# is 'a) is emitted as a reactor rather than a command, so it never reaches
# this path at all.
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

# ---- the command component, through wasi ---------------------------------
#
# `exit` has to be a statement here, not the tail: a program whose main
# expression is `exit n` has type 'a, and the component emitter only builds the
# command shape for unit / int.

comp_checked=0
if command -v wasm-tools >/dev/null 2>&1 && command -v wasmtime >/dev/null 2>&1; then
  for pair in "0 0" "7 1"; do
    set -- $pair
    code=$1; want=$2
    printf 'let _ = print "before" in\nlet _ = exit %s in\n()\n' "$code" > "$TMP/comp$code.mere"
    if MERE="$MERE" bash "$ROOT/scripts/build-component.sh" "$TMP/comp$code.mere" "$TMP/comp$code.wasm" >/dev/null 2>&1; then
      wasmtime run "$TMP/comp$code.wasm" >/dev/null 2>&1; crc=$?
      if [ "$crc" != "$want" ]; then
        if [ "$code" = 7 ]; then
          echo "FAIL component: exit 7 gave $crc, expected 1 — wasi:cli/exit is func(status: result) and carries no number. If a status arrived, say so here and in Q-114."
        else
          echo "FAIL component: exit 0 gave $crc, expected 0"
        fi
        fail=1
      fi
      comp_checked=$((comp_checked + 1))
      checked=$((checked + 1))
    else
      echo "exit_status_check: the component leg did not build (no wasi adapter?) — not measured"
      break
    fi
  done
else
  echo "exit_status_check: no wasm-tools/wasmtime — the component leg is not measured"
fi

# A gate that checked nothing would print the same success line as one that
# checked everything (a skipped toolchain is how that happens), so the count is
# part of the verdict.
if [ "$checked" -lt 6 ]; then
  echo "FAIL exit_status_check: only $checked backend runs happened — a toolchain is missing and this gate is not measuring what it claims"
  exit 1
fi

if [ "$fail" = 0 ]; then
  if [ "$comp_checked" -gt 0 ]; then
    echo "PASS exit_status_check: $checked backend runs, exit codes agree (component leg included: 0 -> 0, 7 -> 1, which is all wasi:cli/exit can say)"
  else
    echo "PASS exit_status_check: $checked backend runs, exit codes agree (component leg not measured)"
  fi
  exit 0
fi
exit 1
