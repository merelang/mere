#!/bin/sh
# scripts/infer_scaling.sh — check that type-checking stays linear in the number
# of bindings.
#
# It was quadratic until v0.1.220: `generalize` scanned the whole environment for
# every binding, which nobody noticed while the compiler ran once per file and
# which cost 5.3 seconds per keystroke once the LSP started re-checking whole
# documents. A correctness test cannot see this — the answers were right, there
# were just O(N^2) of them — so the guard has to be a measurement.
#
# Two files, eight times apart. Linear predicts 8x, quadratic predicts 64x. The
# bound is 20x, which is far enough above 8 to survive a loaded machine and far
# enough below 64 to fail the moment the environment scan comes back.
#
# Skips (exit 0) when python3 is missing (used for sub-second timing).
#
# Usage:
#   sh scripts/infer_scaling.sh

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}
SMALL=2000
LARGE=16000
MAX_RATIO=20

if ! command -v python3 >/dev/null 2>&1; then
  echo "infer_scaling: python3 not found — skipping (this check is optional)"
  exit 0
fi

if [ ! -x "$MERE" ]; then
  echo "infer_scaling: $MERE not found — run dune build first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Independent bindings: each one is a separate generalization, and none of them
# constrains another, so what is being measured is the per-binding cost and not
# the shape of any particular program.
gen() {
  python3 -c "
import sys
n = int(sys.argv[1])
with open(sys.argv[2], 'w') as f:
    for i in range(n):
        f.write(f'let f{i} = fn (x: int) -> x + {i};\n')
    f.write('let _ = print_int (f0 1);\n')
" "$1" "$2"
}

gen "$SMALL" "$TMP/small.mere"
gen "$LARGE" "$TMP/large.mere"

# Best of three: the machine is shared with whatever else is running, and the
# fastest run is the one least contaminated by that.
time_of() {
  python3 -c "
import subprocess, sys, time
best = None
for _ in range(3):
    t = time.time()
    subprocess.run([sys.argv[1], '-t', sys.argv[2]],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    d = time.time() - t
    best = d if best is None else min(best, d)
print(f'{best:.4f}')
" "$MERE" "$1"
}

small=$(time_of "$TMP/small.mere")
large=$(time_of "$TMP/large.mere")

python3 -c "
import sys
small, large, cap = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
n_small, n_large = int(sys.argv[4]), int(sys.argv[5])
ratio = large / small if small > 0 else float('inf')
growth = n_large / n_small
print(f'  {n_small:6d} bindings  {small*1000:7.1f}ms')
print(f'  {n_large:6d} bindings  {large*1000:7.1f}ms   ({ratio:.1f}x for {growth:.0f}x the bindings)')
if ratio > cap:
    print(f'infer_scaling: FAILED — {ratio:.1f}x exceeds the {cap:.0f}x bound; '
          f'inference looks superlinear again (quadratic would be ~{growth**2:.0f}x)')
    sys.exit(1)
print('infer_scaling: ok')
" "$small" "$large" "$MAX_RATIO" "$SMALL" "$LARGE"
