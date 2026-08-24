#!/bin/sh
# scripts/bench_check.sh — the half of the benchmark suite that can be a gate.
#
# benchmarks/run.py prints a RECORD: wall clock and peak RSS for the same
# program written in several languages. None of that belongs in CI. Wall clock
# on a shared runner is a measurement of the runner, and peak RSS is quantized
# to powers of two and stops reproducing above a few GB -- a threshold on
# either would go red for reasons that have nothing to do with the commit.
#
# What IS checkable is everything the machine does not get a vote on:
#
#   1. Every implementation of a benchmark PRINTS THE SAME BYTES. This is the
#      load-bearing one. A benchmark whose implementations disagree is timing
#      two different programs, and the disagreement shows up as a flattering
#      number for whichever one does less work -- which is exactly the shape a
#      language author wants to be true, and therefore the shape that has to be
#      checked by a machine.
#
#   2. Mere's programs still BUILD. The suite's subject failing to compile once
#      reported as a green run here, because the failure was printed and then
#      not counted. It is counted now.
#
#   3. The default region's cumulative allocation stays inside a recorded band.
#      alloc_total is a function of the program, not of the machine, so a bound
#      on it is tight and meaningful in a way a time bound never is. Bands live
#      in each benchmark's MANIFEST with the measurement that set them.
#      Both directions: a reading below the floor means the METER broke, and a
#      gate that cannot see its subject passes forever.
#
# Reference toolchains that are absent on this machine are SKIPPED with a
# printed reason. That is a real weakening of check 1 -- a suite that silently
# drops the fast competitor reads as a win -- so the skip lines are output, not
# silence.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"

[ -x "$MERE" ] || { echo "bench_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || {
  echo "bench_check: python3 absent (it is the runner and the input generator)" >&2
  exit 0; }

python3 "$ROOT/benchmarks/run.py" --verify-only
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL bench_check: see above"
  exit 1
fi
echo "PASS bench_check: implementations agree, and Mere's allocation is in band"
