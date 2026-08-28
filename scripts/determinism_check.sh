#!/bin/sh
# scripts/determinism_check.sh — assert the precondition the parity harness rests on.
#
# scripts/parity.sh compares each backend's stdout against the interpreter's and
# calls a difference a bug. That comparison only means something if stdout is a
# FUNCTION OF THE PROGRAM. Two host builtins break that outright:
#
#   time         reads the wall clock
#   random_int   reads a PRNG seeded from time ^ pid
#   random_float same (no C lowering yet, see "unanswerable" below)
#
# A case using one of these does not produce a stable DIFF that DIVERGE could pin —
# it produces a different answer every run, on one backend, on one machine. The
# harness has no name for that, and until this gate there was nothing stopping such
# a case from being added: the discipline existed only as a comment inside
# test/parity/time_clock.mere.
#
# Environment-dependent builtins (args / env_var / read_file / read_stdin / run) are
# NOT in scope: the harness runs every backend with the same argv, env, cwd and
# stdin, so those are fixed inputs, not ambient nondeterminism. Scheduling order
# (spawn / channel_*) is a third kind and is NOT checked here — saying so because a
# gate that quietly covers two of three kinds reads as if it covered all three.
#
# HOW IT ASKS. Not with grep. test/parity/toplevel_shadows_builtin.mere binds
# `random_int` at top level as a user function, and a text search reports that as a
# use — the string is present, the property is not. So each case is emitted to C and
# the CALL SITES are counted, with the definitions the prelude always contains
# subtracted. That is the compiler's own answer about which builtin the name reached.
#
# ALLOWLIST. test/parity/DETERMINISM_ALLOW holds `<case> <reason>` lines for cases
# that legitimately touch one, having converted the nondeterministic value into a
# deterministic assertion. An entry whose case no longer calls the builtin is an
# ERROR, not a pass: the gate detects that it was fixed, so the list cannot rot.
#
# UNANSWERABLE. If the C backend refuses a case, this oracle cannot see inside it.
# Those are listed, never silently skipped. `random_float` has no C lowering, so a
# case using it would land here rather than be caught.
#
# Usage: scripts/determinism_check.sh
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
DIR=test/parity
ALLOW=$DIR/DETERMINISM_ALLOW

[ -x "$MERE" ] || { echo "determinism_check: no compiler at $MERE (run dune build)"; exit 1; }

# builtin name -> emitted C symbol
SYMS="time:__lang_time random_int:__lang_random_int random_float:__lang_random_float"

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

examined=0; unanswerable=0; violations=0; allow_used=0; stale=0
: > "$tmp/uses"; : > "$tmp/unans"

for f in "$DIR"/*.mere "$DIR"/fail/*.mere; do
  [ -f "$f" ] || continue
  case=$(basename "$f" .mere)
  if ! "$MERE" -c "$f" > "$tmp/em.c" 2>"$tmp/err"; then
    unanswerable=$((unanswerable + 1))
    echo "$case: $(head -1 "$tmp/err" | cut -c1-90)" >> "$tmp/unans"
    continue
  fi
  examined=$((examined + 1))
  for pair in $SYMS; do
    name=${pair%%:*}; sym=${pair#*:}
    total=$(grep -c "$sym" "$tmp/em.c" 2>/dev/null); total=${total:-0}
    defs=$(grep -cE "^static .*$sym[[:space:]]*\(" "$tmp/em.c" 2>/dev/null); defs=${defs:-0}
    calls=$((total - defs))
    [ "$calls" -gt 0 ] && echo "$case $name" >> "$tmp/uses"
  done
done

# A gate that examined nothing must not report success.
if [ "$examined" -eq 0 ]; then
  echo "determinism_check: FAIL — examined 0 cases (the gate did not run)"
  exit 1
fi

allowed_case() { grep -qE "^$1([[:space:]]|$)" "$ALLOW" 2>/dev/null; }

while read -r case name; do
  if allowed_case "$case"; then
    allow_used=$((allow_used + 1))
    echo "  ALLOWED  $case uses $name — $(grep -E "^$case([[:space:]]|$)" "$ALLOW" | cut -d' ' -f2-)"
  else
    violations=$((violations + 1))
    echo "  VIOLATION $case calls $name: stdout is not a function of the program,"
    echo "            so parity.sh cannot compare it. Convert the value to a"
    echo "            structural assertion (see time_clock.mere), or add it to"
    echo "            $ALLOW with the reason."
  fi
done < "$tmp/uses"

# An allowlist entry whose case no longer calls anything is stale: say so.
if [ -f "$ALLOW" ]; then
  while read -r case _rest; do
    case "$case" in ''|'#'*) continue ;; esac
    if ! grep -qE "^$case " "$tmp/uses"; then
      stale=$((stale + 1))
      echo "  STALE    $ALLOW lists $case, which no longer calls one. Remove the entry."
    fi
  done < "$ALLOW"
fi

if [ "$unanswerable" -gt 0 ]; then
  echo "  unanswerable (C refused; this oracle cannot see inside): $unanswerable"
  sed 's/^/    /' "$tmp/unans"
fi

echo "determinism_check: examined $examined cases, ${allow_used} allowed, ${violations} violations, ${stale} stale"
[ "$violations" -eq 0 ] && [ "$stale" -eq 0 ] || exit 1
exit 0
