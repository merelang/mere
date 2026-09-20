#!/bin/sh
# scripts/alloc_meter_check.sh — Q-138: the allocation meter, and whether it is
# measuring anything.
#
# Until v0.1.488 `MERE_REGION_STATS` existed in codegen_c.ml and nowhere else, so
# "this change cut allocation" was a sentence only the C backend could be asked
# to check. Q-135 (24 bytes per saturated application, v0.1.481-482) was verified
# on C alone for that reason, and the other three backends were taken on trust.
#
# The Wasm meter is two numbers the module already almost had: the bump pointer,
# which is where allocation has reached, and `__lang_reclaimed`, everything a
# region release has taken back. Their sum is the total handed out. The bump
# ALONE is a lower bound -- that is what makes the second number necessary, and
# it is also the number the C backend does not have, because its regions free
# whole blocks and never report how much was in them.
#
# WHAT IS CHECKED
#   1. silent by default        -- in BYTES on stderr, not "the string is empty"
#   2. the report is coherent   -- alloc_total = live + reclaimed
#   3. three implementations agree -- on a program with no region block, the
#      Wasm, LLVM and C totals are within 1% of each other. A meter checked only
#      against itself is checking nothing; the measured spread is 18 bytes on
#      262 KB, and each of the three counts in a different place (a bump global,
#      one allocator function, a struct field).
#   4. the region case reclaims -- ≥90% of the total goes back
#   5. it responds to the subject -- twice the work reports ~twice the bytes. A
#      meter stuck on a constant passes 1-4 and fails this.
#
# Usage:
#   sh scripts/alloc_meter_check.sh            # check
#   sh scripts/alloc_meter_check.sh --poison   # check that it can go red
#
# THE POISONS aim at the two comparisons, because those are the checks with any
# power and they are the ones that can rot into tautologies:
#   1. the agreement check is pointed at the REGION program, where the two
#      backends legitimately differ by about 2x (Wasm's vec_push cannot extend a
#      buffer in place while a block is open, so growth reallocates). It must go
#      red. If it passes, the 1% band is not being applied to anything.
#   2. the doubling check is pointed at one program against ITSELF, ratio 1.0.
#      It must go red.
# with a control run first, so red means the poison.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
CASES="$ROOT/test/allocmeter"

[ -x "$MERE" ] || { echo "alloc_meter: $MERE not built" >&2; exit 2; }

for t in node wat2wasm clang; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "alloc_meter: $t not found — skipping (this check needs all three)"
    exit 0; }
done

tmp="${TMPDIR:-/tmp}/alloc_meter.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

fails=0
note() { echo "  $*"; fails=$((fails + 1)); }

build_wasm() { # name
  "$MERE" -w "$CASES/$1.mere" >"$tmp/$1.wat" 2>"$tmp/$1.emit" || {
    echo "alloc_meter: -w failed on $1"; sed -n 1,5p "$tmp/$1.emit"; exit 1; }
  wat2wasm --enable-tail-call "$tmp/$1.wat" -o "$tmp/$1.wasm" || {
    echo "alloc_meter: wat2wasm failed on $1"; exit 1; }
}
build_c() { # name
  "$MERE" -c "$CASES/$1.mere" >"$tmp/$1.c" 2>/dev/null || {
    echo "alloc_meter: -c failed on $1"; exit 1; }
  clang -O1 -o "$tmp/$1.cbin" "$tmp/$1.c" || {
    echo "alloc_meter: clang failed on $1"; exit 1; }
}
build_ll() { # name
  "$MERE" -ll "$CASES/$1.mere" >"$tmp/$1.ll" 2>/dev/null || {
    echo "alloc_meter: -ll failed on $1"; exit 1; }
  # -Woverride-module: the emitted triple is generic and clang says so on every
  # build here. Silenced rather than suppressed with 2>/dev/null, so a REAL
  # error still reaches the log.
  clang -O1 -Wno-override-module -o "$tmp/$1.llbin" "$tmp/$1.ll" || {
    echo "alloc_meter: clang failed on $1.ll"; exit 1; }
}

# field <name> <key> -> the number the wasm meter reported for <key>
wasm_field() {
  MERE_REGION_STATS=1 node "$ROOT/scripts/run_wasm.js" "$tmp/$1.wasm" \
    >/dev/null 2>"$tmp/$1.err"
  sed -n "s|^region-stats wasm: .*$2=\([0-9][0-9]*\).*|\1|p" "$tmp/$1.err" | head -1
}
c_default_total() { # name
  MERE_REGION_STATS=1 "$tmp/$1.cbin" >/dev/null 2>"$tmp/$1.cerr"
  sed -n 's|^region-stats default: .*alloc_total=\([0-9][0-9]*\).*|\1|p' "$tmp/$1.cerr" | head -1
}
ll_total() { # name
  MERE_REGION_STATS=1 "$tmp/$1.llbin" >/dev/null 2>"$tmp/$1.llerr"
  sed -n 's|^region-stats llvm: alloc_total=\([0-9][0-9]*\).*|\1|p' "$tmp/$1.llerr" | head -1
}

# within <a> <b> <percent> -> 0 when |a-b| <= percent% of the larger
within() {
  awk -v a="$1" -v b="$2" -v p="$3" 'BEGIN {
    m = (a > b ? a : b); if (m == 0) exit 1
    d = (a > b ? a - b : b - a)
    exit (d * 100 <= p * m) ? 0 : 1 }'
}

for n in noregion noregion2x region; do build_wasm "$n"; done
build_c noregion
build_ll noregion

# 1. silent unless asked. Counted in bytes: a heading with nothing under it and
#    no heading at all are the same string once the shell strips newlines.
node "$ROOT/scripts/run_wasm.js" "$tmp/noregion.wasm" >/dev/null 2>"$tmp/quiet.err"
qb=$(wc -c <"$tmp/quiet.err" | tr -d ' ')
[ "$qb" = "0" ] || note "the meter wrote $qb bytes to stderr with MERE_REGION_STATS unset"

# 2-5. the numbers.
w_total=$(wasm_field noregion alloc_total)
w_live=$(wasm_field noregion live)
w_recl=$(wasm_field noregion reclaimed)
[ -n "$w_total" ] || note "no wasm report at all for noregion"

if [ -n "$w_total" ]; then
  sum=$((w_live + w_recl))
  [ "$sum" = "$w_total" ] \
    || note "incoherent report: live($w_live) + reclaimed($w_recl) = $sum, alloc_total=$w_total"
fi

c_total=$(c_default_total noregion)
[ -n "$c_total" ] || note "no C report for noregion"
l_total=$(ll_total noregion)
[ -n "$l_total" ] || note "no LLVM report for noregion"
# The LLVM meter is silent unless asked, the same as the other two.
"$tmp/noregion.llbin" >/dev/null 2>"$tmp/llquiet.err"
lqb=$(wc -c <"$tmp/llquiet.err" | tr -d ' ')
[ "$lqb" = "0" ] || note "the LLVM meter wrote $lqb bytes to stderr with MERE_REGION_STATS unset"
if [ -n "$w_total" ] && [ -n "$c_total" ] && [ -n "$l_total" ]; then
  if within "$w_total" "$c_total" 1 && within "$l_total" "$c_total" 1; then
    echo "alloc_meter: C $c_total B / LLVM $l_total B / wasm $w_total B on one program (within 1%)"
  else
    note "the three backends disagree: C=$c_total LLVM=$l_total wasm=$w_total"
  fi
fi

r_total=$(wasm_field region alloc_total)
r_recl=$(wasm_field region reclaimed)
if [ -n "$r_total" ] && [ "$r_total" -gt 0 ] 2>/dev/null; then
  pct=$(awk -v a="$r_recl" -v b="$r_total" 'BEGIN { printf "%d", a * 100 / b }')
  if [ "$pct" -ge 90 ]; then
    echo "alloc_meter: the region block gave back ${pct}% of $r_total B (C has no number for this)"
  else
    note "the region block reclaimed only ${pct}% ($r_recl of $r_total)"
  fi
else
  note "no wasm report for the region case"
fi

d_total=$(wasm_field noregion2x alloc_total)
if [ -n "$d_total" ] && [ -n "$w_total" ]; then
  if within "$d_total" "$((w_total * 2))" 10; then
    echo "alloc_meter: twice the work reports $d_total B against $w_total B (within 10% of 2x)"
  else
    note "doubling the work did not double the number: $w_total -> $d_total"
  fi
fi

if [ "${1:-}" = "--poison" ]; then
  [ "$fails" = 0 ] || { echo "poison: CONTROL IS NOT GREEN ($fails)"; exit 1; }
  echo "poison: control green"
  p=0
  # 1: the agreement band, pointed at the pair that legitimately differs.
  if within "$r_total" "$c_total" 1; then
    echo "poison 1 (agreement vs the region program): FAILED — the 1% band accepted wasm=$r_total C=$c_total"
    p=$((p + 1))
  else
    echo "poison 1 (agreement vs the region program): red — wasm=$r_total C=$c_total is caught"
  fi
  # 2: the doubling band, pointed at one program against itself.
  if within "$w_total" "$((w_total * 2))" 10; then
    echo "poison 2 (doubling vs itself): FAILED — the 10% band accepted a ratio of 1.0"
    p=$((p + 1))
  else
    echo "poison 2 (doubling vs itself): red — a ratio of 1.0 is caught"
  fi
  [ "$p" = 0 ] || exit 1
  echo "alloc_meter: poison ok (2 poisons + control)"
  exit 0
fi

[ "$fails" = 0 ] || { echo "alloc_meter: $fails problem(s)"; exit 1; }
echo "alloc_meter: ok"
