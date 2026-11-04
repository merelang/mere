#!/bin/sh
# scripts/rv_arena_sweep_check.sh — on RISC-V, a container's arena goes with
# the region block that rolled the container back.
#
# v0.1.694. The RV64 backend gives a container an arena of its own the first
# time it is compacted or recycled, as C does. A region block's exit rolls its
# bump range back, and with it the cells of the containers made inside; their
# arenas stayed on no list and went back to nobody -- the hole v0.1.688 closed
# on C. Each arena now names its container and carries a serial, and the exit
# frees the arenas made since the block was entered whose container lies in the
# range it rolled back. On a coroutine's chain of blocks this is done only when
# that range is inside one block (a rollback that went back along the chain
# keeps everything, the arenas with it).
#
# v0.1.696. Without coroutines an arena block was cut from gp and raised the
# block's high-water mark, which kept the containers -- and so their arenas --
# too. A program that compacts or recycles a container now gets the layout a
# coroutine program has, and its arenas are cut from the top of the heap.
#
# WHAT IS CHECKED: test/region_deps/rv_rounds makes a hundred compacted maps of
# 8 KB inside a region and leaves it, twenty times, with a coroutine alive, in
# a 16 MB machine; rv_rounds_nocoro does the same with no coroutine. Each must
# print 2000 and "done". Leaving the arenas behind, they run out of memory on
# the fourth round or so.
#
# --poison: rv_rounds compiled with MERE_RV_NO_ARENA_SWEEP=1 (the exit does not
# sweep) and rv_rounds_nocoro with MERE_RV_NO_ARENA_LAYOUT=1 (arenas cut from
# gp) must each run out of memory.
#
# Needs a memu checkout: MEMU=<memu>. Without one there is nothing to run the
# program on: exit 2.
#
# Usage:
#   MEMU=/path/to/memu sh scripts/rv_arena_sweep_check.sh
#   MEMU=/path/to/memu sh scripts/rv_arena_sweep_check.sh --poison
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "rv_arena_sweep: $MERE not built" >&2; exit 2; }
[ -n "${MEMU:-}" ] && [ -f "$MEMU/riscv-runc/rv64i_run.mere" ] || { echo "rv_arena_sweep: no MEMU checkout -- nothing to run RV64 on"; exit 2; }
CC="${CC:-cc}"; command -v "$CC" >/dev/null 2>&1 || { echo "rv_arena_sweep: no C compiler -- cannot answer"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$MERE" -c "$MEMU/riscv-runc/rv64i_run.mere" > "$T/rvrun64.c" 2> "$T/err" \
  && "$CC" -O2 -w "$T/rvrun64.c" -o "$T/rvrun64" -lm -lpthread 2> "$T/err" \
  || { echo "rv_arena_sweep: FAIL the RV64 emulator did not build: $(head -1 "$T/err")"; exit 1; }

# $1 = the program (under test/region_deps), $2 = an environment setting or ""
# -> the run's output, one line
run() {
  env $2 "$MERE" -rv64 --ram 16 "$ROOT/test/region_deps/$1.mere" > "$T/prog.bin" 2> "$T/err" \
    || { echo "compile: $(head -1 "$T/err")"; return 0; }
  ( cd "$T" && perl -e 'alarm 300; exec @ARGV' ./rvrun64 16 2>&1 ) | grep -a -v '^rvrun' | tr '\n' ' '
}

if [ "${1:-}" = --poison ]; then
  bad=0
  for case in "rv_rounds MERE_RV_NO_ARENA_SWEEP=1" "rv_rounds_nocoro MERE_RV_NO_ARENA_LAYOUT=1"; do
    set -- $case
    out=$(run "$1" "$2")
    case "$out" in
      *"out of memory"*) echo "rv_arena_sweep: poison ok -- $1 with $2: $out" ;;
      *) echo "rv_arena_sweep: POISON $1 with $2 did not run out of memory: $out"; bad=1 ;;
    esac
  done
  exit $bad
fi
bad=0
for p in rv_rounds rv_rounds_nocoro; do
  out=$(run "$p" "")
  if [ "$out" = "2000 done " ]; then echo "rv_arena_sweep: ok -- $p: twenty rounds of 100 compacted maps fit in 16 MB"
  else echo "rv_arena_sweep: FAIL -- $p: expected \"2000 done\": $out"; bad=1; fi
done
exit $bad
