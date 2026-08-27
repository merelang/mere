#!/bin/sh
# scripts/section_coverage.sh -- every hand-written runtime section has a
# program that reaches it.
#
# WHAT THIS IS. Parts of the Wasm runtime are emitted as literal WAT text and
# gated behind a flag that only a program using that feature sets. Text that is
# never emitted is never validated, never linked and never run, so a
# representation change walks past it and nothing goes red. Q-068 and Q-069
# were both exactly that, found on the same day, in sections that had been
# wrong since values widened.
#
# WHAT IT CHECKS.
#
#   1. Every flag-gated section in lib/codegen_wasm.ml has a row in
#      test/parity/SECTIONS. A section nobody wrote down is a section nobody
#      decided about.
#   2. Every COVERED row is actually reached: the named program is compiled and
#      its WAT must contain the section's marker. Naming a program that does
#      not reach it is the failure this is here to prevent.
#   3. Every COVERED section is reached by SOME parity program (the named one
#      is a pointer, not the only permitted source).
#   4. UNREACHABLE rows must still be unreachable. If any parity program starts
#      emitting one, the row is stale and says something untrue -- so the gate
#      fails and asks for it to be promoted, rather than passing quietly.
#
# WHY THE MARKERS ARE READ FROM THE COMPILER SOURCE. Copying the flag list here
# would make this agree with a snapshot of the backend instead of the backend.
# A new gated section with no row fails check 1 on the commit that adds it.
#
# NEGATIVE TEST: delete a row; point a COVERED row at a program that does not
# use the feature; or add a gated section to codegen_wasm.ml without a row.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
TABLE="$ROOT/test/parity/SECTIONS"
SRC="$ROOT/lib/codegen_wasm.ml"
BOUND="${SECTION_TIMEOUT:-60}"
[ -x "$MERE" ] || { echo "section_coverage: $MERE not found -- run 'dune build'" >&2; exit 1; }
[ -f "$TABLE" ] || { echo "section_coverage: $TABLE not found" >&2; exit 1; }

fails=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. the compiler's gated sections all have rows --------------------------
sed -n 's/.*if not !\([a-z_][a-z_]*\) then "" else.*/\1/p' "$SRC" | sort -u > "$TMP/flags"
[ -s "$TMP/flags" ] || { echo "FAIL section_coverage: no gated sections found in codegen_wasm.ml -- the extractor lost its subject"; exit 1; }
while read -r flag; do
  grep -q "^$flag[[:space:]]" "$TABLE" || {
    echo "FAIL section_coverage[$flag]: gated section has no row in test/parity/SECTIONS"
    fails=$((fails + 1)); }
done < "$TMP/flags"

# --- compile the corpus once and keep every module's text --------------------
for f in "$ROOT"/test/parity/*.mere; do
  n="$(basename "$f" .mere)"
  sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" -w "$f" > "$TMP/wat.$n" 2>/dev/null || rm -f "$TMP/wat.$n"
done
emitted=$(ls "$TMP" | grep -c '^wat\.' || true)
[ "$emitted" -gt 0 ] || { echo "FAIL section_coverage: no parity program emitted Wasm -- nothing was measured"; exit 1; }

rows=0
while read -r flag marker status rest; do
  case "$flag" in ''|\#*) continue ;; esac
  rows=$((rows + 1))
  # who actually emits it?
  hits="$(grep -l "\$$marker" "$TMP"/wat.* 2>/dev/null | sed 's/.*\/wat\.//' | tr '\n' ' ')"
  case "$status" in
    COVERED)
      if [ -z "$hits" ]; then
        echo "FAIL section_coverage[$flag]: marked COVERED and no parity program emits \`$marker\`"
        fails=$((fails + 1))
      else
        named="${rest%%.mere*}"
        named="${named##* }"
        [ -z "$named" ] || [ -f "$TMP/wat.$named" ] || named=""
        if [ -n "$named" ] && ! grep -q "\$$marker" "$TMP/wat.$named"; then
          echo "FAIL section_coverage[$flag]: row names $named.mere, which does not emit \`$marker\` (reached by:$hits)"
          fails=$((fails + 1))
        fi
      fi ;;
    UNREACHABLE)
      if [ -n "$hits" ]; then
        echo "FAIL section_coverage[$flag]: marked UNREACHABLE but reached by:$hits -- promote the row to COVERED"
        fails=$((fails + 1))
      fi ;;
    *)
      echo "FAIL section_coverage[$flag]: unknown status \`$status\` (want COVERED or UNREACHABLE)"
      fails=$((fails + 1)) ;;
  esac
done < "$TABLE"

if [ "$fails" -gt 0 ]; then
  echo "FAIL section_coverage: $fails problem(s) across $rows rows"
  exit 1
fi
unreach=$(awk '$1 !~ /^#/ && NF && $3 == "UNREACHABLE"' "$TABLE" | wc -l | tr -d ' ')
echo "PASS section_coverage: $rows sections, $emitted programs compiled, $unreach declared unreachable"
