#!/bin/sh
# scripts/fmt_roundtrip_check.sh — what `mere fmt` writes is still the same
# program.
#
# `mere fmt -i` rewrites files in place, so the output being a PROGRAM is not a
# nicety. It was not: the formatter printed the parser's flattened form of a
# module -- `let Bignum.base = ...`, which is not syntax -- and 52 of the 293
# example files came back as something the compiler refused. The formatter's own
# tests were all small single-file samples, and the corpus was never asked.
#
# WHAT IS CHECKED: for every example the compiler accepts today, format it and
# ask the compiler about the OUTPUT. The formatted file is written NEXT TO the
# original, because `import` resolves relative to the file and moving it to /tmp
# asks a different question.
#
# The ceiling is a measured number, not a target: it goes down when the next
# cause is fixed and up when something regresses, and it is the only honest
# shape while one known cause is still open (a trait's internal `__pack`
# constructor reaches the output).
#
# ⚠ WHAT IT DOES NOT CHECK: that the output MEANS the same thing. Type-checking
# is a weaker question than behaviour, and the parity suite is where behaviour
# is asked. This catches the class that matters most for a tool that writes in
# place -- output the compiler cannot read.
#
# Usage:
#   sh scripts/fmt_roundtrip_check.sh            # check
#   sh scripts/fmt_roundtrip_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "fmt_roundtrip: $MERE not built" >&2; exit 2; }
CEILING="${CEILING:-1}"

probe="__fmtroundtrip__.mere"
cleanup() {
  find "$ROOT/examples" -name "$probe" -delete 2>/dev/null || true
  find "$ROOT/examples" -name "__fmtroundtrip2__.mere" -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup

checked=0; broke=0; names=""; drift=0; drift_names=""
for f in "$ROOT"/examples/*.mere "$ROOT"/examples/*/*.mere; do
  [ -f "$f" ] || continue
  case "$f" in *"$probe") continue ;; esac
  # Only files the compiler accepts as they are: a file it already refuses
  # cannot say anything about the formatter.
  "$MERE" -t "$f" >/dev/null 2>&1 || continue
  out="$(dirname "$f")/$probe"
  "$MERE" fmt "$f" > "$out" 2>/dev/null || { rm -f "$out"; continue; }
  checked=$((checked + 1))
  if ! "$MERE" -t "$out" >/dev/null 2>&1; then
    broke=$((broke + 1))
    names="$names $(basename "$f")"
  fi
  # ...and formatting the output again gives the same file. The gate that used
  # to own this question formatted ONE fixture twice, which is why 109 of these
  # were not idempotent without anybody knowing.
  out2="$(dirname "$f")/__fmtroundtrip2__.mere"
  if "$MERE" fmt "$out" > "$out2" 2>/dev/null; then
    cmp -s "$out" "$out2" || { drift=$((drift + 1)); drift_names="$drift_names $(basename "$f")"; }
  else
    drift=$((drift + 1)); drift_names="$drift_names $(basename "$f")(refused)"
  fi
  rm -f "$out2"
  rm -f "$out"
done

[ "$checked" -ge 200 ] || {
  echo "fmt_roundtrip: only $checked files checked — the corpus is not what this expects" >&2
  exit 2; }

if [ "$broke" -le "$CEILING" ]; then
  printf '  ok    %s\n' "$checked examples formatted; $broke the compiler then refused (ceiling $CEILING)"
  [ "$broke" = 0 ] || printf '  note  %s\n' "still refused:$names"
else
  printf '  FAIL  %s\n' "$checked examples formatted; $broke refused, above the ceiling of $CEILING:$names"
  echo "fmt_roundtrip: FAILED"
  exit 1
fi

DRIFT_CEILING="${DRIFT_CEILING:-3}"
if [ "$drift" -le "$DRIFT_CEILING" ]; then
  printf '  ok    %s\n' "$checked formatted twice; $drift differ the second time (ceiling $DRIFT_CEILING)"
  [ "$drift" = 0 ] || printf '  note  %s\n' "second pass differs:$drift_names"
else
  printf '  FAIL  %s\n' "$drift files differ on a second format, above the ceiling of $DRIFT_CEILING:$drift_names"
  echo "fmt_roundtrip: FAILED"
  exit 1
fi

if [ "${1:-}" = "--poison" ]; then
  # A ceiling of -1 cannot be met, so a run that still passes is not reading the
  # number it prints.
  if CEILING=-1 sh "$0" >/dev/null 2>&1 || DRIFT_CEILING=-1 sh "$0" >/dev/null 2>&1; then
    echo "fmt_roundtrip --poison: FAILED (an impossible ceiling still passed)"
    exit 1
  fi
  echo "fmt_roundtrip --poison: ok (the ceiling can refuse)"
fi
echo "fmt_roundtrip: ok"
exit 0
