#!/bin/sh
# scripts/selfhost_check.sh — functional equivalence between OCaml
# `mere` and the self-hosted Mere-in-Mere compiler.
#
# For each input .mere file: compile it with BOTH compilers, assemble
# each output, run each Wasm binary, and diff the captured stdout.
# Passes when every input produces byte-identical output through both
# pipelines — proves the self-host compiler is functionally correct
# even though its emitted WAT looks different (bigger, less pruned).
#
# Bit-identity of the WAT is a separate (unmet) goal.
#
# Usage:
#   sh scripts/selfhost_check.sh                 # runs the default set
#   sh scripts/selfhost_check.sh path/to/input.mere ...   # custom
#
# Prerequisites:
#   - dune-built `_build/default/bin/mere.exe` (`dune build`)
#   - `wat2wasm` on PATH (wabt)
#   - `node` on PATH
#   - Self-hosted CLI Wasm at /tmp/selfmere.wasm — this script builds
#     it if it doesn't exist.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MERE="$ROOT/_build/default/bin/mere.exe"
RUN="node $ROOT/scripts/run_wasm.js"
SELF="/tmp/selfmere.wasm"

if [ ! -x "$MERE" ]; then
  echo "selfhost_check: $MERE not found — run 'dune build' first" >&2
  exit 1
fi

if [ ! -f "$SELF" ]; then
  echo "== bootstrap: building self-hosted compiler =="
  "$MERE" -w examples/selfhost_wasm_cli.mere > /tmp/selfmere.wat
  wat2wasm --enable-tail-call /tmp/selfmere.wat -o "$SELF"
fi

check_one() {
  input="$1"
  name=$(basename "$input" .mere)
  ref_wat="/tmp/${name}_ref.wat"
  ref_wasm="/tmp/${name}_ref.wasm"
  self_wat="/tmp/${name}_self.wat"
  self_wasm="/tmp/${name}_self.wasm"
  ref_out="/tmp/${name}_ref.out"
  self_out="/tmp/${name}_self.out"

  # OCaml mere pipeline
  "$MERE" -w "$input" > "$ref_wat"
  wat2wasm --enable-tail-call "$ref_wat" -o "$ref_wasm" 2>/dev/null
  $RUN "$ref_wasm" > "$ref_out" 2>&1

  # Self-hosted pipeline (`sed '$d'` strips main's `()` auto-print)
  $RUN "$SELF" "$input" 2>/dev/null | sed '$d' > "$self_wat"
  wat2wasm --enable-tail-call "$self_wat" -o "$self_wasm" 2>/dev/null
  $RUN "$self_wasm" > "$self_out" 2>&1

  # OCaml codegen always appends a `()` (or a stringified return value)
  # line after main returns. Self-host's codegen doesn't. Strip the
  # last line of the reference output — this is a known gap tracked
  # in the comment block above. Inputs that only produce output via
  # explicit `print` calls are unaffected by the stripping (their
  # meaningful output is in the earlier lines).
  ref_out_norm="${ref_out}.norm"
  sed '$d' "$ref_out" > "$ref_out_norm"

  if diff -q "$ref_out_norm" "$self_out" >/dev/null; then
    ref_lines=$(wc -l < "$ref_wat" | tr -d ' ')
    self_lines=$(wc -l < "$self_wat" | tr -d ' ')
    printf "  ok  %-40s ref=%s self=%s\n" "$name" "$ref_lines" "$self_lines"
    return 0
  else
    printf "  FAIL %-40s\n" "$name"
    echo "    reference output (normalized, trailing auto-print stripped):"
    sed 's/^/      /' "$ref_out_norm"
    echo "    self-host output:"
    sed 's/^/      /' "$self_out"
    return 1
  fi
}

if [ $# -gt 0 ]; then
  inputs="$*"
else
  # Default set — small unit-typed programs under test/selfhost/ that
  # produce their meaningful output via explicit `print` calls. That
  # bypasses the known "self-host doesn't auto-print main's return"
  # gap (see below).
  #
  # Known self-host gaps that this script surfaces:
  #   1. Main return-value auto-print not emitted by self-host. OCaml
  #      appends `puts(show_int(result))` for int-typed main and
  #      `puts("()")` for unit-typed main. Self-host emits neither.
  #      The check normalizes by stripping the last line of OCaml
  #      output before comparing, which works for programs whose
  #      meaningful output is in earlier print lines. Programs that
  #      rely on main-return-as-output (e.g. `fib 15` at the end
  #      with no explicit print) fail.
  #      Fix: port lib/codegen_wasm.ml:5171 "match main_ty_walked" to
  #      contrib/codegen/codegen_wasm.mere. Requires calling contrib/typer
  #      first to know main's inferred type.
  #   2. Preamble emission is unconditional in self-host — always emits
  #      all runtime helpers regardless of usage. Doesn't affect
  #      correctness, only file size (self-host output is ~2.7x bigger).
  inputs="\
    test/selfhost/t01_hello.mere \
    test/selfhost/t02_arith.mere \
    test/selfhost/t03_fib.mere \
    test/selfhost/t04_string.mere \
    test/selfhost/t05_list.mere \
  "
fi

echo "== self-host functional equivalence =="
failed=0
for f in $inputs; do
  if [ ! -f "$f" ]; then
    printf "  SKIP %-40s (file not found)\n" "$(basename "$f")"
    continue
  fi
  if ! check_one "$f"; then
    failed=$((failed + 1))
  fi
done

if [ $failed -eq 0 ]; then
  echo "all passed"
  exit 0
else
  echo "$failed failure(s)"
  exit 1
fi
