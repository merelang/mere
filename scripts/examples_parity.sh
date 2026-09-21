#!/bin/sh
# scripts/examples_parity.sh — run the examples corpus on the interpreter and
# on the C backend and require the same bytes.
#
# WHY, WHEN parity.sh EXISTS. parity.sh compares four backends on 178 programs
# written for it. examples/ holds 291 programs written for people, and nothing
# compared them across backends at all -- `check_cmd_check.sh` sweeps the same
# tree but asks only whether a program is ACCEPTED, never what it prints.
#
# The difference is not hypothetical. The first run of this found
# `examples/vec_higher_order.mere` printing
#
#     xs:      Vec[1, 2, 3, 4, 5]        (interpreter)
#     xs:      <unknown>                 (C backend)
#
# -- `show` of a Vec, wrong on a shipped example, for as long as both had
# existed. A hand-written suite cannot cover the shape nobody thought of; a
# corpus can, because it was written for other reasons.
#
# WHAT IT RUNS. Every example that the INTERPRETER runs to completion in a few
# seconds with no input. That is the selector, and it is deliberately dumb:
# anything needing a port, a file, a terminal or a network answers non-zero or
# times out and is skipped, with the count reported so a corpus that quietly
# stops running is visible.
#
# WHY THE C BACKEND AND NOT ALL FOUR. C is the one every example can be built
# for; LLVM and Wasm decline whole categories by design (documented limits),
# and a gate that has to know which is which becomes a second parity harness.
# One backend that never declines is enough to catch a divergence: the bug
# above would have been caught by any of them.
#
# Usage:
#   sh scripts/examples_parity.sh            # check
#   sh scripts/examples_parity.sh --poison   # check that it can go red

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "examples_parity: $MERE not built" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || {
  echo "examples_parity: clang not found — skipping"; exit 0; }

tmp="${TMPDIR:-/tmp}/examples_parity.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

# `timeout` is not on a stock macOS, and this has to run in both places.
to() { perl -e 'alarm shift; exec @ARGV' "$@"; }

poison="${1:-}"
skipped=0; compared=0; bad=0; buildfail=0; nondet=0

for f in "$ROOT"/examples/*.mere; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  # THE SELECTOR: does the interpreter finish, quietly, on its own?
  if ! to 10 "$MERE" "$f" >"$tmp/i.out" 2>"$tmp/i.err" </dev/null; then
    skipped=$((skipped + 1)); continue
  fi
  if ! to 120 "$MERE" -c "$f" >"$tmp/p.c" 2>/dev/null \
     || ! clang -O0 -w -o "$tmp/pc" "$tmp/p.c" 2>/dev/null; then
    # A documented codegen refusal is not a divergence -- it is this backend
    # saying what it does not do. Counted, so the number is visible.
    buildfail=$((buildfail + 1)); continue
  fi
  to 30 "$tmp/pc" >"$tmp/c.out" 2>/dev/null </dev/null
  compared=$((compared + 1))
  # IS THE OUTPUT A FUNCTION OF THE PROGRAM? Asked here rather than by keeping
  # a list of the ones that print a clock -- `examples/log_levels_demo.mere`
  # stamps every line with `time ()`, and a list of such files goes stale the
  # day somebody adds another. Asked AFTER the C build, not next to the first
  # run: back to back the two interpreter runs land in the same second and a
  # per-second clock looks stable. The gap is the build, which is seconds, so
  # nothing here is a fixed sleep guessing at the machine. This is
  # determinism_check.sh's precondition, asked per example.
  if ! to 10 "$MERE" "$f" >"$tmp/i2.out" 2>/dev/null </dev/null \
     || ! cmp -s "$tmp/i.out" "$tmp/i2.out"; then
    nondet=$((nondet + 1)); compared=$((compared - 1)); continue
  fi
  # The poison rewrites one answer, so a gate that is not comparing must fail.
  if [ "$poison" = "--poison" ] && [ "$compared" = 1 ]; then
    echo "poisoned" >"$tmp/c.out"
  fi
  if ! cmp -s "$tmp/i.out" "$tmp/c.out"; then
    bad=$((bad + 1))
    echo "  $name"
    diff "$tmp/i.out" "$tmp/c.out" 2>/dev/null | head -4 | sed 's/^/      /'
  fi
done

if [ "$poison" = "--poison" ]; then
  if [ "$bad" -ge 1 ]; then
    echo "examples_parity: poison ok — the rewritten answer was caught"
    exit 0
  fi
  echo "examples_parity: POISON FAILED — a rewritten answer went unnoticed"
  exit 1
fi

echo "examples_parity: compared $compared, skipped $skipped (need input/ports/time), \
$nondet not a function of the program, $buildfail refused by the C backend"
if [ "$bad" != 0 ]; then
  echo "examples_parity: $bad example(s) differ between the interpreter and C"
  exit 1
fi
# A corpus that stops being compared passes forever: the count is the guard.
if [ "$compared" -lt 150 ]; then
  echo "examples_parity: only $compared examples were compared — the selector or \
the corpus changed; a sweep this small is not the one these numbers were set for"
  exit 1
fi
echo "examples_parity: ok"
