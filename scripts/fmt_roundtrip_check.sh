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
CEILING="${CEILING:-0}"

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

DRIFT_CEILING="${DRIFT_CEILING:-0}"
if [ "$drift" -le "$DRIFT_CEILING" ]; then
  printf '  ok    %s\n' "$checked formatted twice; $drift differ the second time (ceiling $DRIFT_CEILING)"
  [ "$drift" = 0 ] || printf '  note  %s\n' "second pass differs:$drift_names"
else
  printf '  FAIL  %s\n' "$drift files differ on a second format, above the ceiling of $DRIFT_CEILING:$drift_names"
  echo "fmt_roundtrip: FAILED"
  exit 1
fi

# --- IS IT THE SAME PROGRAM? (Q-174) ---------------------------------------
#
# ⚠ The two questions above are BOTH "is the output broken". They were both
# green while `mere fmt` DELETED every `import` line and wrote the imported
# files' declarations into the user's file instead -- the inlined output
# type-checks and is stable on a second pass, so neither could see it. A
# transform needs at least one check that names what must be PRESERVED.
TMPOUT=$(mktemp)
badimp=""; nimp=0
for f in "$ROOT"/examples/*.mere; do
  want=$(grep -c '^import ' "$f" 2>/dev/null || true)
  [ "$want" != "0" ] || continue
  "$MERE" -t "$f" >/dev/null 2>&1 || continue
  "$MERE" fmt "$f" > "$TMPOUT" 2>/dev/null || continue
  nimp=$((nimp + 1))
  got=$(grep -c '^import ' "$TMPOUT" 2>/dev/null || true)
  [ "$want" = "$got" ] || badimp="$badimp $(basename "$f")($want->$got)"
done
rm -f "$TMPOUT"
if [ "$nimp" -lt 20 ]; then
  echo "fmt_roundtrip: only $nimp examples with imports — the corpus is not what this expects" >&2
  exit 2
fi
if [ -z "$badimp" ]; then
  printf '  ok    %s\n' "$nimp examples with imports keep every one of them"
else
  printf '  FAIL  %s\n' "fmt changed how many imports a file has:$badimp"
  echo "fmt_roundtrip: FAILED"
  exit 1
fi

# And the declarations the import used to splice in must NOT be written into the
# file. Counting imports alone would pass a formatter that kept the line AND
# inlined the file.
IT=$(mktemp -d)
mkdir -p "$IT/sub"
printf 'let a_helper_from_elsewhere = fn (n: int) -> n + 1;\n' > "$IT/sub/lib.mere"
printf 'import "sub/lib.mere";\nlet mine = 1;\nprint_int (a_helper_from_elsewhere mine)\n' > "$IT/p.mere"
if "$MERE" fmt "$IT/p.mere" > "$IT/out" 2>/dev/null; then
  if grep -q 'a_helper_from_elsewhere = ' "$IT/out"; then
    printf '  FAIL  %s\n' "the imported file's declaration was written into the output"
    rm -rf "$IT"; echo "fmt_roundtrip: FAILED"; exit 1
  elif grep -q '^import "sub/lib.mere";' "$IT/out"; then
    printf '  ok    %s\n' "the import line comes back and the imported declaration does not"
  else
    printf '  FAIL  %s\n' "the import line did not come back"
    rm -rf "$IT"; echo "fmt_roundtrip: FAILED"; exit 1
  fi
else
  printf '  FAIL  %s\n' "the fixture with an import could not be formatted"
  rm -rf "$IT"; echo "fmt_roundtrip: FAILED"; exit 1
fi
rm -rf "$IT"

if [ "${1:-}" = "--poison" ]; then
  # A ceiling of -1 cannot be met, so a run that still passes is not reading the
  # number it prints.
  if CEILING=-1 sh "$0" >/dev/null 2>&1 || DRIFT_CEILING=-1 sh "$0" >/dev/null 2>&1; then
    echo "fmt_roundtrip --poison: FAILED (an impossible ceiling still passed)"
    exit 1
  fi
  # ⚠ The import question needs its OWN poison: a ceiling poison cannot reach it,
  # because the bug it stands for made the count go to zero and this gate had no
  # count at all. A file whose import cannot be resolved is skipped by the walk,
  # so the poison is the fixture with the imported file taken away -- the
  # formatter must not answer for it.
  PT=$(mktemp -d)
  printf 'import "gone/missing.mere";\nprint_int 1\n' > "$PT/p.mere"
  if "$MERE" fmt "$PT/p.mere" >/dev/null 2>&1; then
    echo "fmt_roundtrip --poison: FAILED (an unresolvable import still formatted)"
    rm -rf "$PT"; exit 1
  fi
  rm -rf "$PT"
  echo "fmt_roundtrip --poison: ok (the ceiling can refuse, and an import it cannot read is not answered for)"
fi
echo "fmt_roundtrip: ok"
exit 0
