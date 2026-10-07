#!/bin/sh
# rv_failure_check.sh -- a failing program fails the same way on RISC-V as on
# the C backend: the same stdout, the same stderr, the same exit status
# (v0.1.637, Q-200).
#
# Until then the Mere-written CPU printed the guest's stderr on its own stdout
# and ended 0 whatever the guest's exit asked for; an uncaught `fail "boom"`
# printed `boom` (no `fail: ` tag unless the program used try_or_msg), and a
# vec_get out of range said "index out of bounds" without the index or the
# length. Every gate that compared the two backends merged the streams, so
# none of it showed.
#
# Each fixture in test/rv/fail ends in a failure (or catches one): C is the
# reference, and RV64 and RV32 on memu must agree on all three. memu's own
# diagnostics ("rvrun..." lines) are not the guest's and are dropped.
#
# Usage:
#   MEMU=<memu checkout> sh scripts/rv_failure_check.sh
#   MEMU=<memu checkout> sh scripts/rv_failure_check.sh --poison
#     (the RV stderr is folded into its stdout, the shape before 0.1.637: the
#      check must go red)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
MODE="${1:-}"
[ -x "$MERE" ] || { echo "rv_failure: $MERE not found -- run 'dune build'" >&2; exit 1; }
if [ -z "${MEMU:-}" ] || [ ! -f "$MEMU/riscv-runc/rv64i_run.mere" ]; then
  echo "rv_failure: cannot answer (set MEMU to a memu checkout)"; exit 2
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for w in 32 64; do
  "$MERE" -c "$MEMU/riscv-runc/rv${w}i_run.mere" > "$TMP/rv$w.c" 2>/dev/null \
    && $CC -O2 -w -o "$TMP/rvrun$w" "$TMP/rv$w.c" -lm 2>/dev/null \
    || { echo "FAIL rv_failure: the RV$w emulator did not build"; exit 1; }
done

pass=0; fail=0
for f in "$ROOT"/test/rv/fail/*.mere; do
  n=$(basename "$f" .mere)
  "$MERE" -c "$f" > "$TMP/c.c" 2>/dev/null && $CC -O1 -w -o "$TMP/c" "$TMP/c.c" 2>/dev/null \
    || { echo "  FAIL  $n: the C reference did not build"; fail=$((fail+1)); continue; }
  ( cd "$TMP" && ./c > c.out 2> c.err ); crc=$?
  for w in 64 32; do
    flag=-rv64; [ "$w" = 32 ] && flag=-rv
    if ! "$MERE" $flag --ram 16 "$f" > "$TMP/prog.bin" 2>/dev/null; then
      echo "  FAIL  $n:$w did not build"; fail=$((fail+1)); continue
    fi
    if [ "$MODE" = "--poison" ]; then
      ( cd "$TMP" && perl -e 'alarm 120; exec @ARGV' ./rvrun$w 16 > r.raw 2>&1 ); rrc=$?
      : > "$TMP/r.eraw"
    else
      ( cd "$TMP" && perl -e 'alarm 120; exec @ARGV' ./rvrun$w 16 > r.raw 2> r.eraw ); rrc=$?
    fi
    grep -a -v '^rvrun' "$TMP/r.raw" > "$TMP/r.out"
    grep -a -v '^rvrun' "$TMP/r.eraw" > "$TMP/r.err"
    why=""
    cmp -s "$TMP/c.out" "$TMP/r.out" || why="$why stdout"
    cmp -s "$TMP/c.err" "$TMP/r.err" || why="$why stderr"
    [ "$crc" = "$rrc" ] || why="$why exit($crc vs $rrc)"
    if [ -z "$why" ]; then pass=$((pass+1))
    else
      fail=$((fail+1)); echo "  FAIL  $n:RV$w differs in$why"
      [ "$MODE" = "--poison" ] || { echo "    C   err: $(head -1 "$TMP/c.err")"; echo "    RV  err: $(head -1 "$TMP/r.err")"; }
    fi
  done
done

if [ "$MODE" = "--poison" ]; then
  if [ "$fail" -gt 0 ]; then echo "rv_failure: poison ok -- with the streams folded, $fail of $((pass+fail)) go red"; exit 0; fi
  echo "rv_failure: POISON FAILED -- folding stderr into stdout went unnoticed"; exit 1
fi
echo "rv_failure: $pass passed, $fail failed (stdout, stderr and the exit status against C, RV64 and RV32)"
[ "$fail" = 0 ]
