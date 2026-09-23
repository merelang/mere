#!/bin/sh
# scripts/fail_reason_check.sh — the reason a caught failure gives is the line
# the uncaught one prints.
#
# WHY. `try_or` could see THAT something failed and not WHY: what it handed back
# was the default, and the message the raiser wrote went nowhere. `try_or_msg`
# (Q-165) hands the handler that message, which raises a question no test could
# ask before -- is it the SAME message? A backend that kept a different string,
# or truncated it, or handed back the last failure instead of this one, would
# still look right to every existing gate, because until now nothing in the
# language could read the string at all.
#
# WHAT IS CHECKED. test/parity/fail/reason_*.mere each contain ONE failing
# expression written TWICE: once inside `try_or_msg`, whose handler prints what
# it was told, and once bare, so the process ends with that same failure. The
# two strings must be equal -- the last line of stdout, and the message the
# diagnostic carries. Twelve kinds: `fail` itself, assert, the three division
# forms, pow, int_of_str, and five range errors raised inside the backend rather
# than by the program.
#
# Run on the interpreter and on every compiled backend that can be built here,
# because the interpreter is the one that has the message in hand (an OCaml
# exception carries it) and the compiled ones are where it has to survive a
# longjmp or a flag: C and LLVM copy it into a fixed buffer before jumping,
# Wasm copies it into reserved memory because the bump it was written in can be
# rolled back before anyone reads it.
#
# WHAT IT DOES NOT CHECK. That the message is any good, and that the set of
# failures a `try_or` can catch is the same on every backend -- it is not known
# to be, and the kinds here are the ones `test/parity/failure_caught.mere`
# already holds to one answer.
#
# Usage:
#   sh scripts/fail_reason_check.sh            # check
#   sh scripts/fail_reason_check.sh --poison   # check that it can go red
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="${M:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$M" ] || { echo "fail_reason: $M is missing (dune build?)" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
have_cc=0; command -v "$CC" >/dev/null 2>&1 && have_cc=1
have_wat=0
command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && have_wat=1

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# The interpreter prefixes its diagnostic; scripts/parity.sh strips the same way.
payload() { sed -e 's/^.*eval error: //' "$1" | head -1; }

# check_one <label> <stdout file> <message file or -> <"out"|"err">
# Prints nothing when the two agree; a line naming the difference when they do not.
compare() {
  _lbl=$1; _out=$2; _msg=$3
  _caught="$(tail -1 "$_out")"
  _uncaught="$(payload "$_msg")"
  if [ -z "$_caught" ]; then
    echo "  $_lbl: printed nothing — the handler did not run"; return 1
  fi
  if [ "$_caught" != "$_uncaught" ]; then
    echo "  $_lbl: caught [$_caught] but uncaught says [$_uncaught]"; return 1
  fi
  return 0
}

run_all() {
  _dir=$1; fails=0; checked=0
  for f in "$_dir"/reason_*.mere; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .mere)"
    checked=$((checked + 1))
    bad=0
    "$M" "$f" > "$T/i.out" 2> "$T/i.err"
    compare "$name interp" "$T/i.out" "$T/i.err" || bad=1
    if [ "$have_cc" = 1 ] && "$M" -c "$f" > "$T/c.c" 2>/dev/null \
       && "$CC" -O0 -w -o "$T/c.bin" "$T/c.c" -lm 2>/dev/null; then
      "$T/c.bin" > "$T/c.out" 2> "$T/c.err"
      compare "$name c" "$T/c.out" "$T/c.err" || bad=1
    fi
    if [ "$have_cc" = 1 ] && "$M" -ll "$f" > "$T/l.ll" 2>/dev/null \
       && "$CC" -O0 -w -o "$T/l.bin" "$T/l.ll" -lm 2>/dev/null; then
      "$T/l.bin" > "$T/l.out" 2> "$T/l.err"
      compare "$name llvm" "$T/l.out" "$T/l.err" || bad=1
    fi
    if [ "$have_wat" = 1 ] && "$M" -w "$f" > "$T/w.wat" 2>/dev/null \
       && wat2wasm --enable-tail-call --enable-threads "$T/w.wat" -o "$T/w.wasm" 2>/dev/null; then
      node "$ROOT/scripts/run_wasm.js" "$T/w.wasm" > "$T/w.out" 2> "$T/w.err"
      # This host has one sink for the diagnostic when WASI is not in play: an
      # empty stderr means the message is the last line of stdout instead, and
      # then the reason the handler printed is the line before it.
      if [ -s "$T/w.err" ]; then
        compare "$name wasm" "$T/w.out" "$T/w.err" || bad=1
      else
        tail -1 "$T/w.out" > "$T/w.msg"
        sed '$d' "$T/w.out" > "$T/w.body"
        compare "$name wasm" "$T/w.body" "$T/w.msg" || bad=1
      fi
    fi
    [ "$bad" = 0 ] || fails=$((fails + 1))
  done
  echo "$checked programs, $fails with a reason that does not match the diagnostic"
  return $fails
}

if [ "${1:-}" = "--poison" ]; then
  # A program whose handler prints something ELSE must be caught. This is the
  # shape of every way the feature can be wrong -- a stale buffer, a truncation,
  # the wrong failure's message -- and none of them would show anywhere else.
  mkdir -p "$T/poison"
  cat > "$T/poison/reason_poison.mere" <<'EOF'
let _ = try_or_msg (fn () -> fail "the real reason") (fn (m: str) -> let _ = print "something else" in 0);
fail "the real reason"
EOF
  if run_all "$T/poison" >/dev/null 2>&1; then
    echo "fail_reason --poison: FAILED (a wrong reason went unnoticed)"; exit 1
  fi
  echo "fail_reason --poison: ok (a wrong reason is reported)"
  exit 0
fi

if run_all "$ROOT/test/parity/fail"; then
  echo "fail_reason: ok"
  exit 0
else
  echo "fail_reason: a caught failure and an uncaught one disagree about why"
  exit 1
fi
