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
#   DIVERGE     differs, and the difference is written down (see below)
#   SKIP        toolchain (llvm/wat2wasm/node) absent
#
# DIVERGE exists because a gate with no place to say "these two legitimately differ
# here" loses the first real divergence it finds: the test gets weakened or deleted,
# and with it everything else the test was checking. A divergence is declared by a
# file next to the case — test/parity/<case>.<backend>.expected — holding that
# backend's output *exactly*. The backend must match that file byte for byte, so the
# known difference is pinned rather than tolerated: any other change is still a
# DIFF, and fixing the underlying limitation breaks the DIVERGE and says so.
#
# A backend that emits successfully but then fails to compile or run, or whose
# output diverges, is a real bug — the "interp-accepts / backend-rejects" and
# "backends-disagree" family this harness exists to catch. A clean "unsupported
# (<backend> codegen ...)" at emit time is a known limitation, not a failure.
#
# test/parity/fail/*.mere are programs that are SUPPOSED to fail. For those the
# comparison is exit status + the stdout written before the failure + the message
# raised. Until v0.1.246 this harness compared stdout and nothing else, so the
# failure surface of the language was the one part of it four implementations were
# never held to — and no parity test used `fail`, because none could have passed:
# the same program exited 1 on two backends and 134 on two others, and wrote its
# diagnostic to a different stream on each half.
#
# Usage:
#   sh scripts/parity.sh                 # runs test/parity/*.mere + test/parity/fail/*.mere
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

# Explicit arguments are partitioned the same way the defaults are: a path under
# test/parity/fail/ is a program that is supposed to fail and goes to the second
# loop. Without this, naming one on the command line ran it as an ordinary test,
# which reported it as a file the interpreter could not run.
if [ $# -gt 0 ]; then
  FILES=""; FAILFILES=""
  for a in "$@"; do
    case "$a" in
      */fail/*) FAILFILES="$FAILFILES $a" ;;
      *)        FILES="$FILES $a" ;;
    esac
  done
else
  FILES="$(ls "$ROOT"/test/parity/*.mere)"
  FAILFILES="$(ls "$ROOT"/test/parity/fail/*.mere 2>/dev/null || true)"
fi

# A clean refusal is a documented limitation, not a failure — and also a case
# that backend did not get checked on. Tallied per backend below.
unsup_c=0; unsup_llvm=0; unsup_wasm=0; unsup_names=""
div_names=""
TMP="${TMPDIR:-/tmp}/mere_parity.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
# A file the interpreter cannot run is not compared on ANY backend, so it is a
# test that does not exist. It used to print one SKIP line and be left out of the
# summary entirely: `trait_default_method.mere` had a parse error from the commit
# that added it (v0.1.101) and sat unnoticed behind `96 passed, 0 failed` for
# 144 versions. Counted, named, and fatal now.
skip=0; skip_names=""

# emit_fail_kind <errfile> : "unsup" if the emit error is a clean
# backend-unsupported, else "hard".
emit_kind() { grep -qE 'unsupported|not supported in .* codegen subset|does not fit the .* 32-bit int' "$1" 2>/dev/null && echo unsup || echo hard; }

# classify_mismatch <backend> <case-file> <actual-output>
# Prints DIVERGE when a declared expectation matches the output exactly, else DIFF.
classify_mismatch() {
  _exp="${2%.mere}.$1.expected"
  if [ -f "$_exp" ] && [ "$3" = "$(cat "$_exp")" ]; then echo DIVERGE; else echo DIFF; fi
}

for f in $FILES; do
  name="$(basename "$f" .mere)"
  ref="$("$MERE" "$f" 2>"$TMP/i.err")" || { echo "SKIP $name (interpreter error)"; sed 's/^/    /' "$TMP/i.err" | head -3; skip=$((skip + 1)); skip_names="$skip_names $name"; continue; }
  row=""; bad=0
  # C
  if "$MERE" -c "$f" > "$TMP/c.c" 2>"$TMP/c.err"; then
    if "$CC" -O0 -w "$TMP/c.c" -o "$TMP/c.bin" -lm 2>"$TMP/c.cc"; then
      out="$("$TMP/c.bin" 2>/dev/null || true)"
      if [ "$out" = "$ref" ]; then row="$row c:MATCH"
      elif [ "$(classify_mismatch c "$f" "$out")" = DIVERGE ]; then
        row="$row c:DIVERGE"; div_names="$div_names c/$name"
      else row="$row c:DIFF"; bad=1; fi
    else row="$row c:MISCOMPILE"; bad=1; fi
  else [ "$(emit_kind "$TMP/c.err")" = unsup ] && row="$row c:UNSUP" || { row="$row c:EMITFAIL"; bad=1; }; fi
  # LLVM
  if "$MERE" -ll "$f" > "$TMP/l.ll" 2>"$TMP/l.err"; then
    if "$CC" -O0 -w "$TMP/l.ll" -o "$TMP/l.bin" -lm 2>"$TMP/l.cc"; then
      out="$("$TMP/l.bin" 2>/dev/null || true)"
      if [ "$out" = "$ref" ]; then row="$row llvm:MATCH"
      elif [ "$(classify_mismatch llvm "$f" "$out")" = DIVERGE ]; then
        row="$row llvm:DIVERGE"; div_names="$div_names llvm/$name"
      else row="$row llvm:DIFF"; bad=1; fi
    else row="$row llvm:MISCOMPILE"; bad=1; fi
  else [ "$(emit_kind "$TMP/l.err")" = unsup ] && row="$row llvm:UNSUP" || { row="$row llvm:EMITFAIL"; bad=1; }; fi
  # Wasm
  if [ "$have_wat" = 1 ]; then
    if "$MERE" -w "$f" > "$TMP/w.wat" 2>"$TMP/w.err"; then
      if wat2wasm --enable-tail-call --enable-threads "$TMP/w.wat" -o "$TMP/w.wasm" 2>"$TMP/w.w2"; then
        out="$(node "$ROOT/scripts/run_wasm.js" "$TMP/w.wasm" 2>/dev/null || true)"
        if [ "$out" = "$ref" ]; then row="$row wasm:MATCH"
      elif [ "$(classify_mismatch wasm "$f" "$out")" = DIVERGE ]; then
        row="$row wasm:DIVERGE"; div_names="$div_names wasm/$name"
      else row="$row wasm:DIFF"; bad=1; fi
      else row="$row wasm:MISCOMPILE"; bad=1; fi
    else [ "$(emit_kind "$TMP/w.err")" = unsup ] && row="$row wasm:UNSUP" || { row="$row wasm:EMITFAIL"; bad=1; }; fi
  else row="$row wasm:SKIP"; fi

  # A pin that no longer describes a divergence is a claim that has stopped being
  # true. v0.1.272 is what made this worth checking: the Wasm backend learned to
  # unwind, `failure_caught` went from DIVERGE to MATCH -- and the .expected file
  # sat there passing quietly, because a matching case never reads it. The gate
  # would have kept a stale declaration on disk indefinitely, which is the exact
  # failure the pin mechanism exists to prevent.
  for b in c llvm wasm; do
    case "$row" in
      *"$b:MATCH"*)
        if [ -f "${f%.mere}.$b.expected" ]; then
          echo "FAIL $name  ($b matches now — delete the stale pin ${f%.mere}.$b.expected)"
          bad=1
        fi ;;
    esac
  done

  # A backend that refused is a backend this case did not check. Counted so
  # the blind spot is a number rather than a word buried in a passing row.
  for b in c llvm wasm; do
    case "$row" in
      *"$b:UNSUP"*) unsup_names="$unsup_names $b/$name"
                    eval "unsup_$b=\$((unsup_$b + 1))" ;;
    esac
  done

  if [ "$bad" = 0 ]; then echo "PASS $name  [interp=$ref ]$row"; pass=$((pass + 1))
  else echo "FAIL $name  [interp=$ref ]$row"; fail=$((fail + 1)); fi
done

# --- programs that are supposed to fail -------------------------------------
#
# Which stream a backend writes an uncaught failure to. interp, C and LLVM use
# stderr. The Wasm JS host ABI has a single sink (`env.puts`), so the diagnostic
# lands in stdout there — a fact about the host rather than about the program,
# written down here so that a change to it breaks this harness instead of passing
# quietly. Under `--component` the same backend writes it to a WASI fd and this
# does not apply; that path is not what this harness runs.
wasm_diag_stream=out

# The message the program raised. Only the interpreter's envelope comes off — it
# names the source file it is running, which a compiled binary does not have. The
# `fail: ` tag is NOT stripped: it is part of the message, added by the `fail`
# builtin, so a backend that forgets it or adds it to its own internal failures
# differs here. Stripping it was the first version of this function, and it made
# the harness unable to see the very difference this slice had just fixed —
# `boom` and `fail: boom` both normalized to `boom`, so removing the fix still
# passed. A normalization is a place a gate stops looking.
# The FIRST line, not the last: a failure the interpreter can point at renders with
# source context under it (`--> file:line`, then the lines), so the last line of that
# is a line of the program. A `fail` call carries no location and renders on one line.
payload() { sed -e 's/^.*eval error: //' "$1" | head -1; }

# $1=label $2=stream(out|err) $3=exit status. Reads $TMP/f.out and $TMP/f.err.
check_fail_backend() {
  _lbl=$1; _stream=$2; _rc=$3
  # Where the diagnostic is decides which end of the file it is at: on stderr it is
  # the whole file and the message is its first line; on a single-sink backend it is
  # the last line of the program's own output.
  if [ "$_stream" = out ]; then
    _pay="$(tail -1 "$TMP/f.out")"; _out="$(sed '$d' "$TMP/f.out")"
  else
    _pay="$(payload "$TMP/f.err")"; _out="$(cat "$TMP/f.out")"
  fi
  if   [ "$_rc" != "$irc" ];    then row="$row $_lbl:EXIT($_rc)"; bad=1
  elif [ "$_out" != "$iout" ];  then row="$row $_lbl:OUT";        bad=1
  elif [ "$_pay" != "$ipay" ];  then row="$row $_lbl:MSG";        bad=1
  else row="$row $_lbl:MATCH"; fi
}

fpass=0; ffail=0
for f in $FAILFILES; do
  name="$(basename "$f" .mere)"
  "$MERE" "$f" > "$TMP/i.out" 2> "$TMP/i.err" && irc=0 || irc=$?
  if [ "$irc" = 0 ]; then
    echo "FAIL $name  (this file is supposed to fail; the interpreter exited 0)"
    ffail=$((ffail + 1)); continue
  fi
  iout="$(cat "$TMP/i.out")"; ipay="$(payload "$TMP/i.err")"
  row=""; bad=0
  # C
  if "$MERE" -c "$f" > "$TMP/c.c" 2>"$TMP/c.err"; then
    if "$CC" -O0 -w "$TMP/c.c" -o "$TMP/c.bin" -lm 2>"$TMP/c.cc"; then
      "$TMP/c.bin" > "$TMP/f.out" 2> "$TMP/f.err" && rc=0 || rc=$?
      check_fail_backend c err "$rc"
    else row="$row c:MISCOMPILE"; bad=1; fi
  else [ "$(emit_kind "$TMP/c.err")" = unsup ] && row="$row c:UNSUP" || { row="$row c:EMITFAIL"; bad=1; }; fi
  # LLVM
  if "$MERE" -ll "$f" > "$TMP/l.ll" 2>"$TMP/l.err"; then
    if "$CC" -O0 -w "$TMP/l.ll" -o "$TMP/l.bin" -lm 2>"$TMP/l.cc"; then
      "$TMP/l.bin" > "$TMP/f.out" 2> "$TMP/f.err" && rc=0 || rc=$?
      check_fail_backend llvm err "$rc"
    else row="$row llvm:MISCOMPILE"; bad=1; fi
  else [ "$(emit_kind "$TMP/l.err")" = unsup ] && row="$row llvm:UNSUP" || { row="$row llvm:EMITFAIL"; bad=1; }; fi
  # Wasm
  if [ "$have_wat" = 1 ]; then
    if "$MERE" -w "$f" > "$TMP/w.wat" 2>"$TMP/w.err"; then
      if wat2wasm --enable-tail-call --enable-threads "$TMP/w.wat" -o "$TMP/w.wasm" 2>"$TMP/w.w2"; then
        node "$ROOT/scripts/run_wasm.js" "$TMP/w.wasm" > "$TMP/f.out" 2> "$TMP/f.err" && rc=0 || rc=$?
        check_fail_backend wasm "$wasm_diag_stream" "$rc"
      else row="$row wasm:MISCOMPILE"; bad=1; fi
    else [ "$(emit_kind "$TMP/w.err")" = unsup ] && row="$row wasm:UNSUP" || { row="$row wasm:EMITFAIL"; bad=1; }; fi
  else row="$row wasm:SKIP"; fi

  if [ "$bad" = 0 ]; then echo "PASS $name  [exit=$irc msg=$ipay ]$row"; fpass=$((fpass + 1))
  else echo "FAIL $name  [exit=$irc msg=$ipay ]$row"; ffail=$((ffail + 1)); fi
done

echo "----"
if [ "$skip" -gt 0 ]; then
  echo "parity: $pass passed, $fail failed, $skip never ran (interpreter error):$skip_names"
else
  echo "parity: $pass passed, $fail failed"
fi
[ "$fpass" -gt 0 ] || [ "$ffail" -gt 0 ] &&
  echo "parity (failing programs): $fpass passed, $ffail failed  [wasm diagnostic stream: $wasm_diag_stream]"
total=$((pass + fail))
[ -n "$div_names" ] && {
  echo "declared divergences (pinned to a .expected file):"
  for entry in $div_names; do echo "    $entry"; done
}
for b in c llvm wasm; do
  eval "n=\$unsup_$b"
  [ "$n" -gt 0 ] && {
    echo "unchecked on $b: $n of $total (refused at emit time)"
    for entry in $unsup_names; do
      case "$entry" in "$b/"*) echo "    ${entry#$b/}" ;; esac
    done
  }
done
[ "$fail" -eq 0 ] && [ "$skip" -eq 0 ] && [ "$ffail" -eq 0 ]
