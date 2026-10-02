#!/bin/sh
# scripts/inner_direct_check.sh -- a saturated call of a curried INNER function
# allocates no closures, on C, LLVM and Wasm (Q-142, v0.1.583).
#
# An inner function is lifted to the top level with what it captures prepended
# to its parameters. Called with all of its arguments -- the inner `go i zx zy`
# of a mandelbrot -- it used to go through the curried chain on LLVM and Wasm,
# one closure environment per application per iteration: the same loop cost 16
# bytes an iteration at top level and 104 nested inside a function on Wasm, and
# examples/mandelbrot.mere took 235 MB on LLVM (6 MB on C) and ran out of memory
# on Wasm. The C backend had the uncurried twin since v0.1.52; the other two
# have it now.
#
#   nested   the loop inside `fn cx -> fn cy -> ...`, capturing cx and cy: must
#            allocate no more than the same loop written at top level (Wasm
#            boxes floats, so its floor is 16 B/iter; C and LLVM allocate
#            nothing per iteration)
#   partial  the inner function applied to one argument and then the rest: the
#            curried chain is still there, and still gives the right answer
#
# --poison: MERE_NO_INNER_DIRECT=1 turns the twin off, and `nested` must then
# blow the bound on every backend.
#
#   sh scripts/inner_direct_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "inner_direct_check: $MERE not built" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "inner_direct_check: no clang" >&2; exit 2; }
HAVE_WASM=1
for t in wat2wasm node; do command -v "$t" >/dev/null 2>&1 || HAVE_WASM=0; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ITERS=96000   # 1000 calls x 96 iterations

cat > "$T/top.mere" <<'EOF'
let max_iter = 96;
let rec go = fn i -> fn (zx: float) -> fn (zy: float) ->
  if i == max_iter then max_iter
  else
    let zx2 = zx * zx in
    let zy2 = zy * zy in
    if zx2 + zy2 > 4.0 then i
    else go (i + 1) (zx2 - zy2 + 0.3) (2.0 * zx * zy + 0.5) in
let rec loop = fn n -> fn acc -> if n == 0 then acc else loop (n - 1) (acc + go 0 0.0 0.0) in
print (show (loop 1000 0))
EOF
cat > "$T/nested.mere" <<'EOF'
let max_iter = 96;
let mandel = fn (cx: float) -> fn (cy: float) ->
  let rec go = fn i -> fn (zx: float) -> fn (zy: float) ->
    if i == max_iter then max_iter
    else
      let zx2 = zx * zx in
      let zy2 = zy * zy in
      if zx2 + zy2 > 4.0 then i
      else go (i + 1) (zx2 - zy2 + cx) (2.0 * zx * zy + cy) in
  go 0 0.0 0.0;
let rec loop = fn n -> fn acc -> if n == 0 then acc else loop (n - 1) (acc + mandel 0.3 0.5) in
print (show (loop 1000 0))
EOF
cat > "$T/partial.mere" <<'EOF'
let scale = fn (k: int) ->
  let rec acc = fn (i: int) -> fn (s: int) -> fn (n: int) ->
    if i == n then s else acc (i + 1) (s + k * i) n in
  let from0 = acc 0 in
  let from0s = from0 0 in
  from0s 10 + acc 0 0 5;
print (show (scale 3))
EOF

# $1 file, $2 c|ll|w -> "bytes output", or "" when it could not be measured
measure() {
  case "$2" in
    c)  "$MERE" -c "$1" > "$T/x.c" 2>"$T/e" && clang -w -O2 "$T/x.c" -o "$T/x" -lm -lpthread 2>>"$T/e" || return ;;
    ll) "$MERE" -ll "$1" > "$T/x.ll" 2>"$T/e" && clang -w -O2 -x ir "$T/x.ll" -o "$T/x" -lm -lpthread 2>>"$T/e" || return ;;
    w)  "$MERE" -w "$1" > "$T/x.wat" 2>"$T/e" && wat2wasm --enable-tail-call "$T/x.wat" -o "$T/x.wasm" 2>>"$T/e" || return ;;
  esac
  if [ "$2" = w ]; then MERE_REGION_STATS=1 node "$ROOT/scripts/run_wasm.js" "$T/x.wasm" > "$T/out" 2>"$T/err"
  else MERE_REGION_STATS=1 "$T/x" > "$T/out" 2>"$T/err"; fi
  a=$(sed -n 's/^region-stats [a-z]*:.*alloc_total=\([0-9][0-9]*\).*/\1/p' "$T/err" | head -1)
  echo "${a:-?} $(tr '\n' ' ' < "$T/out")"
}

fail=0
want_nested=$("$MERE" "$T/nested.mere")
want_partial=$("$MERE" "$T/partial.mere")
bes="c ll"; [ "$HAVE_WASM" = 1 ] && bes="c ll w"
poison=0; [ "${1:-}" = --poison ] && { poison=1; export MERE_NO_INNER_DIRECT=1; }
pf=0
for be in $bes; do
  set -- $(measure "$T/top.mere" "$be"); top=${1:-}
  set -- $(measure "$T/nested.mere" "$be"); nest=${1:-}; shift 2>/dev/null; nest_out="$*"
  if [ -z "$top" ] || [ -z "$nest" ] || [ "$top" = "?" ] || [ "$nest" = "?" ]; then
    echo "  FAIL  $be: could not measure ($(head -1 "$T/e"))"; fail=1; continue; fi
  bound=$(( top * 2 + 4096 ))
  if [ "$poison" = 1 ]; then
    if [ "$nest" -le "$bound" ]; then
      echo "  FAIL  POISON $be: nested still $nest B with the twin off -- the gate does not witness it"; pf=1
    else echo "  ok    POISON $be: nested $nest B (top-level $top B)"; fi
    continue
  fi
  if [ "$nest" -le "$bound" ] && [ "$nest_out" = "$want_nested" ]; then
    echo "  ok    $be nested: $nest B for $ITERS iterations (top-level $top B)"
  else echo "  FAIL  $be nested: $nest B (bound $bound), printed [$nest_out], wanted [$want_nested]"; fail=1; fi
  set -- $(measure "$T/partial.mere" "$be"); shift 2>/dev/null; part_out="$*"
  if [ "$part_out" = "$want_partial" ]; then echo "  ok    $be partial: $part_out"
  else echo "  FAIL  $be partial: printed [$part_out], wanted [$want_partial]"; fail=1; fi
done
[ "$HAVE_WASM" = 1 ] || echo "  note  wat2wasm/node missing: Wasm not checked"
if [ "$poison" = 1 ]; then
  [ "$pf" = 0 ] || { echo "inner_direct_check --poison: FAILED"; exit 1; }
  echo "inner_direct_check --poison: ok (the gate can go red)"; exit 0
fi
[ "$fail" = 0 ] || { echo "inner_direct_check: FAILED"; exit 1; }
echo "inner_direct_check: ok"
