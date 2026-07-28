#!/bin/sh
# scripts/ctest.sh — native-backend compile-and-run differential test.
#
# For each input .mere file:
#   1. emit C with `mere -c`
#   2. compile the emitted C with the C compiler (syntax + full)
#   3. for extern-free programs, run the native binary and diff its stdout
#      against the interpreter's stdout for the same source
#   4. also emit Wasm (`mere -w`) and assemble it with wat2wasm, when
#      available — the same closure/capture/mangling family, second backend
#
# This catches the family of bugs that are invisible on the interpreter and
# only appear once the emitted C is compiled — undeclared identifiers from
# name-mangling/capture mistakes, closure/type mismatches, missing wrappers.
# The in-process OCaml suite only inspects the emitted C as text, so it never
# saw these; this script actually invokes the C compiler.
#
# A file whose source contains `extern` is compile-checked only (there is no
# linkable symbol for a bare FFI declaration), via `-fsyntax-only`.
#
# Usage:
#   sh scripts/ctest.sh                 # runs test/ctests/*.mere
#   sh scripts/ctest.sh path/to/x.mere ...   # custom set
#
# Prerequisites: dune-built _build/default/bin/mere.exe, a C compiler
# (clang or cc) on PATH.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-clang}"
command -v "$CC" >/dev/null 2>&1 || CC=cc

if [ ! -x "$MERE" ]; then
  echo "ctest: $MERE not found — run 'dune build' first" >&2
  exit 1
fi
if ! command -v "$CC" >/dev/null 2>&1; then
  echo "ctest: no C compiler ($CC) on PATH — skipping" >&2
  exit 0
fi

if [ $# -gt 0 ]; then
  FILES="$*"
else
  FILES="$(ls "$ROOT"/test/ctests/*.mere)"
fi

TMP="${TMPDIR:-/tmp}/mere_ctest.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
for f in $FILES; do
  name="$(basename "$f" .mere)"
  cfile="$TMP/$name.c"
  if ! "$MERE" -c "$f" > "$cfile" 2>"$TMP/emit.err"; then
    echo "FAIL $name: C emission failed"
    sed 's/^/    /' "$TMP/emit.err"
    fail=$((fail + 1))
    continue
  fi
  if grep -q '^extern ' "$f" 2>/dev/null || grep -q '[^_]extern fn' "$f" 2>/dev/null; then
    # FFI declaration present: compile-check only (no linkable symbol).
    if "$CC" -fsyntax-only -w "$cfile" 2>"$TMP/cc.err"; then
      echo "PASS $name (syntax-only, extern)"
      pass=$((pass + 1))
    else
      echo "FAIL $name: emitted C does not compile"
      sed 's/^/    /' "$TMP/cc.err" | head -12
      fail=$((fail + 1))
    fi
    continue
  fi
  bin="$TMP/$name.bin"
  if ! "$CC" -O0 -w "$cfile" -o "$bin" -lm 2>"$TMP/cc.err"; then
    echo "FAIL $name: emitted C does not compile"
    sed 's/^/    /' "$TMP/cc.err" | head -12
    fail=$((fail + 1))
    continue
  fi
  native="$("$bin" 2>/dev/null || true)"
  interp="$("$MERE" "$f" 2>/dev/null || true)"
  if [ "$native" != "$interp" ]; then
    echo "FAIL $name: native/interp mismatch"
    echo "    interp: [$interp]"
    echo "    native: [$native]"
    fail=$((fail + 1))
    continue
  fi
  # Also validate the Wasm backend emits assemblable WAT (wat2wasm), when
  # available. Same closure/capture/mangling family, second backend.
  wasm_note=""
  if command -v wat2wasm >/dev/null 2>&1; then
    if "$MERE" -w "$f" > "$TMP/$name.wat" 2>"$TMP/wat.err"; then
      if wat2wasm --enable-tail-call "$TMP/$name.wat" -o "$TMP/$name.wasm" 2>"$TMP/w2.err"; then
        wasm_note=" +wasm"
      else
        echo "FAIL $name: emitted WAT does not assemble"
        sed 's/^/    /' "$TMP/w2.err" | head -6
        fail=$((fail + 1))
        continue
      fi
    else
      echo "FAIL $name: Wasm emission failed"
      sed 's/^/    /' "$TMP/wat.err" | head -6
      fail=$((fail + 1))
      continue
    fi
  fi
  echo "PASS $name (native == interp: $native)$wasm_note"
  pass=$((pass + 1))
done

echo "----"
echo "ctest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
