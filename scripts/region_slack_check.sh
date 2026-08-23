#!/bin/sh
# scripts/region_slack_check.sh — hold arena capacity to its allocation.
#
# Compiles test/regionstats/slack_probe.mere with the C backend, runs it under
# MERE_REGION_STATS=1 and asserts that the default region's CAPACITY stays
# close to its CUMULATIVE ALLOCATION. The probe makes one giant allocation in
# a stream of small ones -- the pattern that, before v0.1.307, both stranded
# the bump block's tail and became the base of every later doubling, so a
# region could hold several times more capacity than data (measured 1.99x on
# this probe; a large Ruby workload read 17.2 GB of capacity around ~2 GB of
# allocation).
#
# The numbers are functions of the program, not the machine (unlike peak RSS,
# which is quantized to powers of two and stops reproducing above a few GB),
# so the bound can be tight: cap <= alloc * 5/4 + 8 MiB. The old allocator
# fails this at 1.99x; the dedicated-block policy passes at ~1.0007x.
#
# Both directions are checked: a capacity of ZERO (or below the probe's known
# 256 MiB floor) means the meter broke -- a gate that cannot see its subject
# passes forever.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "region_slack_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "region_slack_check: no C compiler" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$MERE" -c "$ROOT/test/regionstats/slack_probe.mere" > "$TMP/p.c" 2>"$TMP/p.err" \
  || { echo "FAIL region_slack: mere -c refused the probe"; cat "$TMP/p.err"; exit 1; }
"$CC" -O2 -w "$TMP/p.c" -o "$TMP/p" 2>"$TMP/cc.err" \
  || { echo "FAIL region_slack: C compile failed"; cat "$TMP/cc.err"; exit 1; }

MERE_REGION_STATS=1 "$TMP/p" >"$TMP/out" 2>"$TMP/stats" || {
  echo "FAIL region_slack: probe exited nonzero"; cat "$TMP/stats"; exit 1; }

line="$(grep '^region-stats default:' "$TMP/stats" || true)"
[ -n "$line" ] || { echo "FAIL region_slack: no region-stats line on stderr"; exit 1; }

cap="$(echo "$line" | sed -n 's/.*cap=\([0-9]*\).*/\1/p')"
alloc="$(echo "$line" | sed -n 's/.*alloc_total=\([0-9]*\).*/\1/p')"

# The probe's giant string alone is 256 MiB; a smaller reading means the
# meter (not the allocator) is broken.
floor=268435456
[ "$alloc" -ge "$floor" ] || {
  echo "FAIL region_slack: alloc_total=$alloc below the probe's known floor ($floor) — meter broken"; exit 1; }
[ "$cap" -ge "$floor" ] || {
  echo "FAIL region_slack: cap=$cap below the probe's known floor ($floor) — meter broken"; exit 1; }

# cap <= alloc * 5/4 + 8 MiB
bound=$(( alloc / 4 * 5 + 8388608 ))
if [ "$cap" -gt "$bound" ]; then
  echo "FAIL region_slack: cap=$cap exceeds bound=$bound (alloc_total=$alloc) — arena slack is back"
  exit 1
fi

echo "PASS region_slack: cap=$cap alloc_total=$alloc (bound=$bound)"

# --- second probe: delete-churn must not allocate per delete (v0.1.316) ------
"$MERE" -c "$ROOT/test/regionstats/delete_churn_probe.mere" > "$TMP/d.c" 2>"$TMP/d.err" \
  || { echo "FAIL region_slack: mere -c refused the delete probe"; cat "$TMP/d.err"; exit 1; }
"$CC" -O2 -w "$TMP/d.c" -o "$TMP/d" 2>"$TMP/dcc.err" \
  || { echo "FAIL region_slack: delete probe C compile failed"; cat "$TMP/dcc.err"; exit 1; }
MERE_REGION_STATS=1 "$TMP/d" >"$TMP/dout" 2>"$TMP/dstats" || {
  echo "FAIL region_slack: delete probe exited nonzero"; cat "$TMP/dstats"; exit 1; }
dline="$(grep '^region-stats default:' "$TMP/dstats" || true)"
[ -n "$dline" ] || { echo "FAIL region_slack: delete probe printed no region-stats"; exit 1; }
dalloc="$(echo "$dline" | sed -n 's/.*alloc_total=\([0-9]*\).*/\1/p')"
# meter validity in the other direction: filling 2000 entries costs at least
# a few hundred KB; a smaller reading means the meter broke, not the allocator
[ "$dalloc" -ge 500000 ] || {
  echo "FAIL region_slack: delete probe alloc_total=$dalloc below its known floor — meter broken"; exit 1; }
if [ "$dalloc" -gt 16777216 ]; then
  echo "FAIL region_slack: delete probe alloc_total=$dalloc exceeds 16 MiB — map_delete is allocating per delete again"
  exit 1
fi
echo "PASS region_slack (delete churn): alloc_total=$dalloc"
