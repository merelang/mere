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
# Exits 3 (optional, not run) when python3 is missing (used for sub-second timing).
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
  exit 3
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
#
# v0.1.581: and ONE GROUP of the same size -- `let rec g0 = ... and g1 = ...`,
# every member reading a name bound before the group. mere-ruby's interpreter is
# a group of a thousand members, and three passes walked the whole environment
# (the typer, the move checker) or the whole program (the C backend's
# instantiation search) once per member: 16,000 members took 3.1 s to check and
# 27.5 s to emit C. The group is measured with `-t` and with `-c`, and the
# independent bindings with `check` too: its unused-binding warning resolved
# every name by walking the scope, 2.2 s at 25,600 `let`s.
gen() {
  python3 -c "
import sys
shape, n = sys.argv[1], int(sys.argv[2])
with open(sys.argv[3], 'w') as f:
    if shape == 'independent':
        for i in range(n):
            f.write(f'let f{i} = fn (x: int) -> x + {i};\n')
        f.write('let _ = print_int (f0 1);\n')
    elif shape == 'maps':
        # v0.1.594: top-level containers used at the end. The environment of the
        # top-level chain was an association list, walked from the end of the
        # program for every name: 8,000 of these took 5 s to check.
        for i in range(n):
            f.write(f'let g{i} = map_new ();\n')
        f.write('let _ = ' + ' '.join(f'let _ = map_set g{i} \"k\" {i} in' for i in range(n)))
        f.write(' print_int (map_len g0);\n')
    elif shape == 'poly':
        # v0.1.594: polymorphic helpers each used at two types. The C backend's
        # instantiation fixpoint visited every spec of every helper per helper.
        for i in range(n // 2):
            f.write(f'let rec plen{i} = fn xs -> (match xs with | Nil -> 0 | Cons (_, r) -> 1 + plen{i} r);\n')
            f.write(f'let u{i} = plen{i} (Cons ({i}, Nil)) + plen{i} (Cons (\"s\", Nil));\n')
        f.write('let _ = print_int u0;\n')
    elif shape == 'inner':
        # v0.1.594: an inner let rec per function. Lifting each one turned every
        # top-level name into a set again.
        for i in range(n):
            f.write(f'let f{i} = fn (x: int) -> let rec go = fn (k: int) -> if k <= 0 then x else go (k - 1) in go x;\n')
        f.write('let _ = print_int (f0 1);\n')
    elif shape == 'chain':
        # v0.1.594: one long + chain, as generated code writes. Its left spine
        # was collected by appending each link to the list of the ones below it.
        f.write('let x = 1;\n')
        f.write('let _ = print_int (' + ' + '.join('x' for _ in range(n)) + ');\n')
    else:
        f.write('let base = 7;\n')
        f.write('let rec g0 = fn (x: int) -> x + base\n')
        for i in range(1, n):
            f.write(f'and g{i} = fn (x: int) -> x + base + {i}\n')
        f.write(';\nlet _ = print_int (g0 1);\n')
" "$1" "$2" "$3"
}

# Best of three: the machine is shared with whatever else is running, and the
# fastest run is the one least contaminated by that.
time_of() {
  python3 -c "
import subprocess, sys, time
best = None
for _ in range(3):
    t = time.time()
    subprocess.run([sys.argv[1], sys.argv[2], sys.argv[3]],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    d = time.time() - t
    best = d if best is None else min(best, d)
print(f'{best:.4f}')
" "$MERE" "$1" "$2"
}

failed=0
check_shape() {
  shape=$1 flag=$2
  gen "$shape" "$SMALL" "$TMP/$shape-small.mere"
  gen "$shape" "$LARGE" "$TMP/$shape-large.mere"
  small=$(time_of "$flag" "$TMP/$shape-small.mere")
  large=$(time_of "$flag" "$TMP/$shape-large.mere")
  python3 -c "
import sys
small, large, cap = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
n_small, n_large = int(sys.argv[4]), int(sys.argv[5])
label = sys.argv[6]
ratio = large / small if small > 0 else float('inf')
growth = n_large / n_small
print(f'  {label}')
print(f'    {n_small:6d} bindings  {small*1000:7.1f}ms')
print(f'    {n_large:6d} bindings  {large*1000:7.1f}ms   ({ratio:.1f}x for {growth:.0f}x the bindings)')
if ratio > cap:
    print(f'infer_scaling: FAILED ({label}) — {ratio:.1f}x exceeds the {cap:.0f}x bound; '
          f'this looks superlinear again (quadratic would be ~{growth**2:.0f}x)')
    sys.exit(1)
" "$small" "$large" "$MAX_RATIO" "$SMALL" "$LARGE" "$shape $flag" || failed=1
}

check_shape independent -t
check_shape independent check
check_shape group -t
check_shape group -c
check_shape maps check
check_shape maps -c
check_shape poly -c
check_shape inner -c
check_shape chain -c

if [ "$failed" = 0 ]; then echo 'infer_scaling: ok'; else exit 1; fi
