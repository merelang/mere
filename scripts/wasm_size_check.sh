#!/bin/sh
# scripts/wasm_size_check.sh -- what the playground actually ships, in bytes.
#
# WHY THIS EXISTS. contrib/site/build_full.sh compiles every playground demo
# to .wasm and the docs site serves those files to browsers. Nothing measured
# them. Between 2026-07 and 2026-09 hello.wasm went from 5.2 KB to 15.0 KB --
# roughly tripled -- and no run, gate or review said a word, because the size
# of a build output is not something any other check looks at.
#
# WHAT IT MEASURES. Every .wasm the real site build produces, against a band
# in scripts/wasm_size_budget.txt. The bands are not targets; they are "this is
# where it was, plus room to breathe in both directions".
#
# BANDS, NOT CEILINGS -- the design is scripts/budget_check.sh's, and the floor
# is the half that matters more. A reading over the ceiling is the regression
# everyone expects. A reading UNDER THE FLOOR means the demo stopped being
# built properly -- a stub, a truncated emit, a compiler that silently dropped
# the program -- and a gate watching only the ceiling calls that a pass, and
# keeps calling it a pass forever.
#
# WHY THIS IS NOT IN budget_check.sh. Same design, different subject and a
# different order of cost: budget_check runs in about a second, and this has to
# compile selfhost-compile.mere, which is most of a minute. Folding this in
# would make a fast gate fifty times slower for everything it already covers.
# The subjects do not overlap -- budget_check measures three example servers,
# this measures what the public site hands a browser.
#
# THE FLOOR IS THE NUMBER THAT MOVES EVERYTHING. Every program carries the
# same prelude, so the smallest demo measures a cost that all of them pay: at
# the time of writing, hello.wasm and fibonacci.wasm are both ~152 functions
# and ~12.7 KB of code section while doing almost nothing. The report prints
# that floor separately, because a change there moves fifteen files at once
# and reading it per-file makes it look like fifteen small regressions.
#
# IT BUILDS ITS OWN SUBJECT. It never measures _site/: that directory is
# gitignored and can be months old. Measuring a stale tree is how the first
# pass at this got numbers from a build two months behind HEAD, and read a
# tripling as "comfortably small".
#
# IT ALSO REPORTS SLACK. A file well under its ceiling prints a `lower it`
# line. A gate that only notices growth lets an improvement be absorbed
# silently, and the ceiling stops meaning anything.
#
# SKIPS LOUDLY, NEVER VACUOUSLY. A missing wat2wasm prints a skip and exits 0.
# But a run that measured zero files is a FAIL: an empty check is not a pass.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
# Overridable so the gate's own failure arms can be poisoned without editing
# the real budget: a check nobody has watched fail is a check nobody has seen.
BUDGET="${WASM_SIZE_BUDGET:-$ROOT/scripts/wasm_size_budget.txt}"

[ -x "$MERE" ] || { echo "wasm_size_check: $MERE not found -- run 'dune build'" >&2; exit 1; }
command -v wat2wasm >/dev/null 2>&1 || { echo "wasm_size_check: SKIP (no wat2wasm)"; exit 0; }
[ -f "$BUDGET" ] || { echo "wasm_size_check: $BUDGET not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "wasm_size_check: building the site (this is the real build, not a paraphrase)"
if ! PATH="$ROOT/_build/default/bin:$PATH" sh "$ROOT/contrib/site/build_full.sh" \
       "$ROOT/docs" "$TMP/site" >"$TMP/build.log" 2>&1; then
  echo "FAIL wasm_size_check: the site build failed"
  tail -20 "$TMP/build.log"
  exit 1
fi

PG="$TMP/site/playground"
[ -d "$PG" ] || { echo "FAIL wasm_size_check: the build produced no playground/"; exit 1; }

checked=0
fails=0
slack=0
floor_name=''
floor_size=0

printf '\n%-26s %9s %9s %9s\n' 'file' 'bytes' 'floor' 'ceiling'
printf -- '------------------------------------------------------------------\n'

for f in "$PG"/*.wasm; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  size="$(wc -c < "$f" | tr -d ' ')"

  # Before the budget lookup, not after: a file with no ceiling still ships,
  # so it still counts toward the floor. Tracking this below the `continue`
  # made the gate name the second-smallest file as the floor, which a poison
  # run caught and ordinary runs never would have.
  if [ "$floor_size" -eq 0 ] || [ "$size" -lt "$floor_size" ]; then
    floor_size="$size"
    floor_name="$name"
  fi

  floor="$(awk -v n="$name" '$1 == n { print $2 }' "$BUDGET")"
  ceiling="$(awk -v n="$name" '$1 == n { print $3 }' "$BUDGET")"
  if [ -z "$ceiling" ]; then
    printf '%-26s %9s %9s %9s   NO BUDGET LINE\n' "$name" "$size" '-' '-'
    echo "FAIL wasm_size_check: $name ships with no recorded band -- add it to $(basename "$BUDGET")"
    fails=$((fails + 1))
    checked=$((checked + 1))
    continue
  fi

  checked=$((checked + 1))
  printf '%-26s %9s %9s %9s' "$name" "$size" "$floor" "$ceiling"

  if [ "$size" -gt "$ceiling" ]; then
    printf '   OVER by %s B\n' "$((size - ceiling))"
    fails=$((fails + 1))
  elif [ "$size" -lt "$floor" ]; then
    printf '   UNDER by %s B\n' "$((floor - size))"
    echo "     a demo this much smaller than recorded probably stopped being"
    echo "     built properly. If it is a real improvement, lower the band."
    fails=$((fails + 1))
  else
    printf '\n'
    head="$(awk -v s="$size" -v c="$ceiling" 'BEGIN { printf "%.0f", (c - s) * 100 / c }')"
    [ "$head" -gt 25 ] && slack=$((slack + 1))
  fi
done

# Every budget line must have a file. A demo that is renamed or dropped leaves
# a line behind that checks nothing, and the file count keeps looking right.
while read -r bname bceil; do
  case "$bname" in ''|\#*) continue ;; esac
  : "$bceil"
  if [ ! -f "$PG/$bname" ]; then
    echo "FAIL wasm_size_check: $bname has a band but the build produced no such file"
    fails=$((fails + 1))
  fi
done < "$BUDGET"

echo
if [ "$checked" -eq 0 ]; then
  echo "FAIL wasm_size_check: measured 0 files -- the build produced no .wasm"
  exit 1
fi

total="$(cat "$PG"/*.wasm | wc -c | tr -d ' ')"
echo "floor: $floor_name at $floor_size B -- every demo pays this before doing anything"
echo "total: $total B across $checked files"
[ "$slack" -gt 0 ] && echo "slack: $slack file(s) sit more than 25% under ceiling; the bands are stale"

if [ "$fails" -gt 0 ]; then
  echo "wasm_size_check: FAIL ($fails)"
  exit 1
fi
echo "wasm_size_check: ok ($checked files)"
