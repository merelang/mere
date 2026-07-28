#!/bin/sh
# scripts/parity.sh — four-backend differential (parity) test.
#
# For each input .mere file, run it through every backend and compare stdout
# against the interpreter (the reference):
#   - interp : mere <file>
#   - c      : mere -c  -> C compiler -> run
#   - llvm   : mere -ll -> C compiler -> run
#   - wasm   : mere -w  -> wat2wasm -> node scripts/run_wasm.js
#
# Per backend the outcome is one of:
#   MATCH       stdout equals the interpreter's
#   DIFF        runs but stdout differs               (failure)
#   MISCOMPILE  emitted but did not compile/run       (failure)
#   UNSUP       backend cleanly refused at emit time  (documented limitation)
#   SKIP        toolchain (llvm/wat2wasm/node) absent
#
# A backend that emits successfully but then fails to compile or run, or whose
# output diverges, is a real bug — the "interp-accepts / backend-rejects" and
# "backends-disagree" family this harness exists to catch. A clean "unsupported
# (<backend> codegen ...)" at emit time is a known limitation, not a failure.
#
# Usage:
#   sh scripts/parity.sh                 # runs test/parity/*.mere
#   sh scripts/parity.sh path/to/x.mere ...
#
# Prerequisites: dune-built mere.exe + a C compiler. LLVM needs the same C
# compiler; Wasm needs wat2wasm (wabt) + node. Missing tools -> that backend
# is SKIPped, not failed.

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
[ -x "$MERE" ] || { echo "parity: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "parity: no C compiler" >&2; exit 0; }
have_wat=0; command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && have_wat=1

[ $# -gt 0 ] && FILES="$*" || FILES="$(ls "$ROOT"/test/parity/*.mere)"
TMP="${TMPDIR:-/tmp}/mere_parity.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# emit_fail_kind <errfile> : "unsup" if the emit error is a clean
# backend-unsupported, else "hard".
emit_kind() { grep -qE 'unsupported|not supported in .* codegen subset' "$1" 2>/dev/null && echo unsup || echo hard; }

for f in $FILES; do
  name="$(basename "$f" .mere)"
  ref="$("$MERE" "$f" 2>"$TMP/i.err")" || { echo "SKIP $name (interpreter error)"; sed 's/^/    /' "$TMP/i.err" | head -3; continue; }
  row=""; bad=0
  # C
  if "$MERE" -c "$f" > "$TMP/c.c" 2>"$TMP/c.err"; then
    if "$CC" -O0 -w "$TMP/c.c" -o "$TMP/c.bin" -lm 2>"$TMP/c.cc"; then
      out="$("$TMP/c.bin" 2>/dev/null || true)"
      [ "$out" = "$ref" ] && row="$row c:MATCH" || { row="$row c:DIFF"; bad=1; }
    else row="$row c:MISCOMPILE"; bad=1; fi
  else [ "$(emit_kind "$TMP/c.err")" = unsup ] && row="$row c:UNSUP" || { row="$row c:EMITFAIL"; bad=1; }; fi
  # LLVM
  if "$MERE" -ll "$f" > "$TMP/l.ll" 2>"$TMP/l.err"; then
    if "$CC" -O0 -w "$TMP/l.ll" -o "$TMP/l.bin" -lm 2>"$TMP/l.cc"; then
      out="$("$TMP/l.bin" 2>/dev/null || true)"
      [ "$out" = "$ref" ] && row="$row llvm:MATCH" || { row="$row llvm:DIFF"; bad=1; }
    else row="$row llvm:MISCOMPILE"; bad=1; fi
  else [ "$(emit_kind "$TMP/l.err")" = unsup ] && row="$row llvm:UNSUP" || { row="$row llvm:EMITFAIL"; bad=1; }; fi
  # Wasm
  if [ "$have_wat" = 1 ]; then
    if "$MERE" -w "$f" > "$TMP/w.wat" 2>"$TMP/w.err"; then
      if wat2wasm --enable-tail-call "$TMP/w.wat" -o "$TMP/w.wasm" 2>"$TMP/w.w2"; then
        out="$(node "$ROOT/scripts/run_wasm.js" "$TMP/w.wasm" 2>/dev/null || true)"
        [ "$out" = "$ref" ] && row="$row wasm:MATCH" || { row="$row wasm:DIFF"; bad=1; }
      else row="$row wasm:MISCOMPILE"; bad=1; fi
    else [ "$(emit_kind "$TMP/w.err")" = unsup ] && row="$row wasm:UNSUP" || { row="$row wasm:EMITFAIL"; bad=1; }; fi
  else row="$row wasm:SKIP"; fi

  if [ "$bad" = 0 ]; then echo "PASS $name  [interp=$ref ]$row"; pass=$((pass + 1))
  else echo "FAIL $name  [interp=$ref ]$row"; fail=$((fail + 1)); fi
done

echo "----"
echo "parity: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
