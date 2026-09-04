#!/bin/sh
# scripts/suggest_check.sh — the region report names the expression that mattered,
# and stays quiet where the region is already written.
#
# `mere --suggest-regions` lists expressions where a `region R { }` would bound
# the footprint. Its first finding is the one this repository already paid for:
# on benchmarks/binarytrees/bench.mere the expression `check (build d)` -- a
# tree built and consumed by a call returning int -- is where one line took the
# program from 169 MiB to 5.5 MiB (bench_pertree.mere). This gate holds the
# report to that finding in both directions:
#
#   1. bench.mere         -> the `check` call is reported, at its line
#   2. bench_pertree.mere -> the same line is NOT reported (the region is there)
#   3. a program with no allocation in any fn -> the report says so in words
#
# A report that names nothing on (1) has stopped seeing its subject; one that
# still names (2) is telling people to wrap what is already wrapped.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "suggest_check: $MERE not found — run 'dune build'" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

naive="$ROOT/benchmarks/binarytrees/bench.mere"
pertree="$ROOT/benchmarks/binarytrees/bench_pertree.mere"

"$MERE" --suggest-regions "$naive" > "$TMP/naive" 2>&1 || {
  echo "FAIL suggest_check: the report exited nonzero on bench.mere"; cat "$TMP/naive"; exit 1; }
line=$(grep -n 'acc + check (build d)' "$naive" | cut -d: -f1)
[ -n "$line" ] || { echo "FAIL suggest_check: bench.mere no longer contains the expression this gate is about"; exit 1; }
grep -q "^$naive:$line:[0-9]*: region candidate: \`check\` returns int and consumes a freshly built tree" "$TMP/naive" || {
  echo "FAIL suggest_check: the report does not name \`check (build d)\` on line $line of bench.mere"
  cat "$TMP/naive"; exit 1; }

"$MERE" --suggest-regions "$pertree" > "$TMP/pertree" 2>&1 || {
  echo "FAIL suggest_check: the report exited nonzero on bench_pertree.mere"; cat "$TMP/pertree"; exit 1; }
pline=$(grep -n 'region R { check (build d) }' "$pertree" | cut -d: -f1)
[ -n "$pline" ] || { echo "FAIL suggest_check: bench_pertree.mere no longer contains its region"; exit 1; }
if grep -q "^$pertree:$pline:" "$TMP/pertree"; then
  echo "FAIL suggest_check: the report names line $pline of bench_pertree.mere, which is already inside a region"
  cat "$TMP/pertree"; exit 1
fi

cat > "$TMP/quiet.mere" <<'MERE'
let rec sum = fn (i: int) -> fn (acc: int) -> if i == 0 then acc else sum (i - 1) (acc + i);
print (str_of_int (sum 100 0))
MERE
"$MERE" --suggest-regions "$TMP/quiet.mere" > "$TMP/quiet" 2>&1 || {
  echo "FAIL suggest_check: the report exited nonzero on a program with nothing to say"; cat "$TMP/quiet"; exit 1; }
grep -q '^no region candidates' "$TMP/quiet" || {
  echo "FAIL suggest_check: an empty report must say so in words"; cat "$TMP/quiet"; exit 1; }

n=$(grep -c 'region candidate:' "$TMP/naive")
echo "PASS suggest_check: bench.mere names \`check (build d)\` (line $line, $n candidates in all); bench_pertree.mere is quiet there; an empty report says so"
