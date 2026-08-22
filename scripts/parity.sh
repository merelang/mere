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

# WHY IT DID NOT COMPILE, NOT JUST THAT IT DID NOT. The compiler's stderr was written to a
# file and thrown away, so a red run said `c:MISCOMPILE llvm:MISCOMPILE` for 116 of 117
# programs and not one word about the reason — and diagnosing it needed a container
# reproducing the runner, because the log had nothing in it. Four days of that.
#
# "Did it refuse" and "did it say why" are different questions, and only the first was
# being asked. Collected into `diag` and printed under the row, three lines per backend:
# the first error is the one to read and the rest are usually its consequences.
note_diag() {  # $1 = label, $2 = file holding the compiler's stderr
  [ -s "$2" ] || return 0
  diag="$diag$(printf '    %s: %s' "$1" "$(head -3 "$2" | sed 's/^/      /' | sed '1s/^ *//' | tr '\n' '~')")"
}

have_wat=0; command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && have_wat=1

# A GATE THAT HANGS IS WORSE THAN ONE THAT FAILS. This harness runs whole programs,
# and a concurrent program can block forever by construction: a channel nobody sends
# to, a join on a worker that never returns. Unbounded, one such case stops the run
# with nothing reported and no log to read -- every case after it becomes unknown too.
#
# How the bound is taken, and why neither timeout(1) nor ulimit -t works, is in
# scripts/bounded.sh -- one copy, shared with scripts/thread_leak_check.sh.
#
# The limit is deliberately generous. It exists to turn "hangs forever" into "reports
# HUNG", not to measure how fast a program is: a tight bound would go red on a loaded
# CI box and teach everyone to ignore the gate.
PARITY_TIMEOUT="${MERE_PARITY_TIMEOUT:-60}"
HUNG_RC=201
bounded() { sh "$ROOT/scripts/bounded.sh" "$PARITY_TIMEOUT" "$@"; }
hung_names=""

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
  ref="$(bounded "$MERE" "$f" 2>"$TMP/i.err")" && iref=0 || iref=$?
  if [ "$iref" = "$HUNG_RC" ]; then
    echo "FAIL $name  (the interpreter did not finish within ${PARITY_TIMEOUT}s)"
    fail=$((fail + 1)); hung_names="$hung_names interp/$name"; continue
  fi
  [ "$iref" = 0 ] || { echo "SKIP $name (interpreter error)"; sed 's/^/    /' "$TMP/i.err" | head -3; skip=$((skip + 1)); skip_names="$skip_names $name"; continue; }
  row=""; bad=0; diag=""
  # C
  if "$MERE" -c "$f" > "$TMP/c.c" 2>"$TMP/c.err"; then
    if "$CC" -O0 -w "$TMP/c.c" -o "$TMP/c.bin" -lm 2>"$TMP/c.cc"; then
      out="$(bounded "$TMP/c.bin" 2>/dev/null)" && orc=0 || orc=$?
      if [ "$orc" = "$HUNG_RC" ]; then row="$row c:HUNG"; bad=1; hung_names="$hung_names c/$name"
      elif [ "$out" = "$ref" ]; then row="$row c:MATCH"
      elif [ "$(classify_mismatch c "$f" "$out")" = DIVERGE ]; then
        row="$row c:DIVERGE"; div_names="$div_names c/$name"
      else row="$row c:DIFF"; bad=1; fi
    else row="$row c:MISCOMPILE"; bad=1; note_diag c "$TMP/c.cc"; fi
  else [ "$(emit_kind "$TMP/c.err")" = unsup ] && row="$row c:UNSUP" || { row="$row c:EMITFAIL"; bad=1; note_diag c "$TMP/c.err"; }; fi
  # LLVM
  if "$MERE" -ll "$f" > "$TMP/l.ll" 2>"$TMP/l.err"; then
    if "$CC" -O0 -w "$TMP/l.ll" -o "$TMP/l.bin" -lm 2>"$TMP/l.cc"; then
      out="$(bounded "$TMP/l.bin" 2>/dev/null)" && orc=0 || orc=$?
      if [ "$orc" = "$HUNG_RC" ]; then row="$row llvm:HUNG"; bad=1; hung_names="$hung_names llvm/$name"
      elif [ "$out" = "$ref" ]; then row="$row llvm:MATCH"
      elif [ "$(classify_mismatch llvm "$f" "$out")" = DIVERGE ]; then
        row="$row llvm:DIVERGE"; div_names="$div_names llvm/$name"
      else row="$row llvm:DIFF"; bad=1; fi
    else row="$row llvm:MISCOMPILE"; bad=1; note_diag llvm "$TMP/l.cc"; fi
  else [ "$(emit_kind "$TMP/l.err")" = unsup ] && row="$row llvm:UNSUP" || { row="$row llvm:EMITFAIL"; bad=1; note_diag llvm "$TMP/l.err"; }; fi
  # Wasm
  if [ "$have_wat" = 1 ]; then
    if "$MERE" -w "$f" > "$TMP/w.wat" 2>"$TMP/w.err"; then
      if wat2wasm --enable-tail-call --enable-threads "$TMP/w.wat" -o "$TMP/w.wasm" 2>"$TMP/w.w2"; then
        out="$(bounded node "$ROOT/scripts/run_wasm.js" "$TMP/w.wasm" 2>/dev/null)" && orc=0 || orc=$?
        if [ "$orc" = "$HUNG_RC" ]; then row="$row wasm:HUNG"; bad=1; hung_names="$hung_names wasm/$name"
      elif [ "$out" = "$ref" ]; then row="$row wasm:MATCH"
      elif [ "$(classify_mismatch wasm "$f" "$out")" = DIVERGE ]; then
        row="$row wasm:DIVERGE"; div_names="$div_names wasm/$name"
      else row="$row wasm:DIFF"; bad=1; fi
      else row="$row wasm:MISCOMPILE"; bad=1; note_diag wasm "$TMP/w.w2"; fi
    else [ "$(emit_kind "$TMP/w.err")" = unsup ] && row="$row wasm:UNSUP" || { row="$row wasm:EMITFAIL"; bad=1; note_diag wasm "$TMP/w.err"; }; fi
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
  else
    echo "FAIL $name  [interp=$ref ]$row"; fail=$((fail + 1))
    # An `if`, not `[ ... ] && printf`: as the last command of a branch under `set -e` a
    # false test is the branch's exit status, and whether that ends the script is exactly
    # the sort of thing that differs between shells this is meant to run under.
    if [ -n "$diag" ]; then printf '%s\n' "$diag" | tr '~' '\n'; fi
  fi
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
  if   [ "$_rc" = "$HUNG_RC" ]; then _tok="HUNG"; hung_names="$hung_names $_lbl/$name"
  elif [ "$_rc" != "$irc" ];    then _tok="EXIT($_rc)"
  elif [ "$_out" != "$iout" ];  then _tok="OUT"
  elif [ "$_pay" != "$ipay" ];  then _tok="MSG"
  else _tok="MATCH"; fi
  # A DIVERGENCE THAT DEPENDS ON THE PLATFORM, pinned rather than deleted. The section
  # above has `.<backend>.expected` for this; this one had nothing, so an answer that is
  # right on one operating system and different on another left the choice between a red
  # gate forever and dropping the program — and dropping it stops asking the question.
  #
  # The pin is per backend AND per `uname -s`, because that is what the difference is: the
  # LLVM backend names a stack overflow on Darwin, where the two calls that find the real
  # stack bounds exist, and cannot elsewhere (v0.1.285). A file named
  # `<program>.<backend>.<uname>.diverge` holds the row token that is accepted there.
  #
  # AND IT DETECTS ITS OWN RETIREMENT. A pin whose backend has started matching is
  # reported as stale and fails, because a pin nobody revisits is a claim that has stopped
  # being true — the whole reason for pinning instead of skipping is to keep asking.
  _pin="${f%.mere}.$_lbl.$(uname -s).diverge"
  if [ "$_tok" = MATCH ]; then
    if [ -f "$_pin" ]; then
      row="$row $_lbl:MATCH(pin is stale: ${_pin#$ROOT/})"; bad=1
    else row="$row $_lbl:MATCH"; fi
  elif [ -f "$_pin" ] && [ "$_tok" = "$(cat "$_pin")" ]; then
    row="$row $_lbl:DIVERGE"; fdiv_names="$fdiv_names $_lbl/$name"
  else
    row="$row $_lbl:$_tok"; bad=1
  fi
}

fpass=0; ffail=0; fdiv_names=""
for f in $FAILFILES; do
  name="$(basename "$f" .mere)"
  bounded "$MERE" "$f" > "$TMP/i.out" 2> "$TMP/i.err" && irc=0 || irc=$?
  if [ "$irc" = 0 ]; then
    echo "FAIL $name  (this file is supposed to fail; the interpreter exited 0)"
    ffail=$((ffail + 1)); continue
  fi
  iout="$(cat "$TMP/i.out")"; ipay="$(payload "$TMP/i.err")"
  row=""; bad=0; diag=""
  # C
  if "$MERE" -c "$f" > "$TMP/c.c" 2>"$TMP/c.err"; then
    if "$CC" -O0 -w "$TMP/c.c" -o "$TMP/c.bin" -lm 2>"$TMP/c.cc"; then
      bounded "$TMP/c.bin" > "$TMP/f.out" 2> "$TMP/f.err" && rc=0 || rc=$?
      check_fail_backend c err "$rc"
    else row="$row c:MISCOMPILE"; bad=1; note_diag c "$TMP/c.cc"; fi
  else [ "$(emit_kind "$TMP/c.err")" = unsup ] && row="$row c:UNSUP" || { row="$row c:EMITFAIL"; bad=1; note_diag c "$TMP/c.err"; }; fi
  # LLVM
  if "$MERE" -ll "$f" > "$TMP/l.ll" 2>"$TMP/l.err"; then
    if "$CC" -O0 -w "$TMP/l.ll" -o "$TMP/l.bin" -lm 2>"$TMP/l.cc"; then
      bounded "$TMP/l.bin" > "$TMP/f.out" 2> "$TMP/f.err" && rc=0 || rc=$?
      check_fail_backend llvm err "$rc"
    else row="$row llvm:MISCOMPILE"; bad=1; note_diag llvm "$TMP/l.cc"; fi
  else [ "$(emit_kind "$TMP/l.err")" = unsup ] && row="$row llvm:UNSUP" || { row="$row llvm:EMITFAIL"; bad=1; note_diag llvm "$TMP/l.err"; }; fi
  # Wasm
  if [ "$have_wat" = 1 ]; then
    if "$MERE" -w "$f" > "$TMP/w.wat" 2>"$TMP/w.err"; then
      if wat2wasm --enable-tail-call --enable-threads "$TMP/w.wat" -o "$TMP/w.wasm" 2>"$TMP/w.w2"; then
        bounded node "$ROOT/scripts/run_wasm.js" "$TMP/w.wasm" > "$TMP/f.out" 2> "$TMP/f.err" && rc=0 || rc=$?
        check_fail_backend wasm "$wasm_diag_stream" "$rc"
      else row="$row wasm:MISCOMPILE"; bad=1; note_diag wasm "$TMP/w.w2"; fi
    else [ "$(emit_kind "$TMP/w.err")" = unsup ] && row="$row wasm:UNSUP" || { row="$row wasm:EMITFAIL"; bad=1; note_diag wasm "$TMP/w.err"; }; fi
  else row="$row wasm:SKIP"; fi

  if [ "$bad" = 0 ]; then echo "PASS $name  [exit=$irc msg=$ipay ]$row"; fpass=$((fpass + 1))
  else
    echo "FAIL $name  [exit=$irc msg=$ipay ]$row"; ffail=$((ffail + 1))
    if [ -n "$diag" ]; then printf '%s\n' "$diag" | tr '~' '\n'; fi
  fi
done

echo "----"
if [ "$skip" -gt 0 ]; then
  echo "parity: $pass passed, $fail failed, $skip never ran (interpreter error):$skip_names"
else
  echo "parity: $pass passed, $fail failed"
fi
[ "$fpass" -gt 0 ] || [ "$ffail" -gt 0 ] &&
  echo "parity (failing programs): $fpass passed, $ffail failed  [wasm diagnostic stream: $wasm_diag_stream]"
if [ -n "$fdiv_names" ]; then
  echo "declared divergences among the failing programs (pinned per platform, $(uname -s)):"
  for entry in $fdiv_names; do echo "    $entry"; done
fi
if [ -n "$hung_names" ]; then
  echo "did not finish within ${PARITY_TIMEOUT}s (raise with MERE_PARITY_TIMEOUT):"
  for entry in $hung_names; do echo "    $entry"; done
fi
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
