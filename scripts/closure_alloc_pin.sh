#!/bin/sh
# scripts/closure_alloc_pin.sh — the uncurried closure entry, pinned in BOTH
# directions (v0.1.481-482).
#
# A closure whose return type is an arrow carries `fn2`, a second entry taking
# both arguments at once, so a SATURATED two-argument call does not build the
# intermediate closure's environment to pass the second one. Before it, that was
# 24 bytes and about 13 nanoseconds per call on every spelling that abstracts
# over the function -- a comparator handed to vec_sort, a function taken as a
# parameter, a trait method read out of its dictionary.
#
# TWO BOUNDS, AND THE SECOND ONE IS THE POINT.
#
#   ceiling  a saturated call allocates nothing. This is the fix.
#   floor    a PARTIAL application still allocates. `fn2` is for two arguments
#            at once; applying one has to keep building a closure, and the
#            two-step path has to still be emitted for every callee that
#            cannot have a twin. A gate that only checked the ceiling would
#            stay green on the day the fallback was deleted -- and then a
#            two-argument callback with no fn2 would call through a null
#            pointer.
#
# Why a measurement and not a grep: v0.1.324 records a fix to this same cost
# that BUILT, kept every gate green, and moved the allocation by zero bytes,
# because the guard it added could never fire. A pattern in the emitted C would
# have been satisfied by that version too. alloc_total is not.
#
#   sh scripts/closure_alloc_pin.sh
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
[ -x "$MERE" ] || { echo "closure_alloc_pin: no compiler at $MERE (run dune build)"; exit 1; }
CC=$(command -v clang || command -v cc) || { echo "closure_alloc_pin: no C compiler"; exit 1; }

N=100000
SORTN=1000           # small on purpose: the Vec's own buffer is not the subject
CEILING=100000       # bytes; the fast path leaves only setup behind
FLOOR=1000000        # bytes; N partial applications cannot be free

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail=0

alloc() { # alloc <file.mere> -> bytes, or -1
  "$MERE" -c "$1" > "$d/p.c" 2>"$d/err" || { echo "  emit failed: $1" >&2; sed -n 1,4p "$d/err" >&2; echo -1; return; }
  "$CC" -O2 -o "$d/p" "$d/p.c" 2>"$d/cc" || { echo "  cc failed: $1" >&2; sed -n 1,4p "$d/cc" >&2; echo -1; return; }
  MERE_REGION_STATS=1 "$d/p" 2>&1 | sed -n 's/.*alloc_total=\([0-9]*\).*/\1/p' | head -1
}

# --- the ceiling: five spellings that all reach a saturated two-argument call.
cat > "$d/fast.mere" <<EOF
trait Ord2 'a { cmp : 'a -> 'a -> int; }
impl Ord2 int { cmp = fn (a: int) -> fn (b: int) -> a - b; }
let add = fn (a: int) -> fn (b: int) -> a + b;
let ap = fn (f: int -> int -> int) -> fn (x: int) -> fn (y: int) -> f x y;
let rec named = fn (i: int) -> fn (acc: int) ->
  if i == 0 then acc else named (i - 1) (add acc i);
let rec param = fn (i: int) -> fn (acc: int) ->
  if i == 0 then acc else param (i - 1) (ap add acc i);
let rec dict = fn (i: int) -> fn (acc: int) ->
  if i == 0 then acc else dict (i - 1) (acc + cmp i 1);
let v = vec_new ();
let rec fill = fn (i: int) -> if i >= $SORTN then () else { vec_push v ((i * 7919) % 99991); fill (i + 1) };
let _ = fill 0;
let _ = vec_sort v (fn (a: int) -> fn (b: int) -> a - b);
let folded = vec_fold v 0 (fn (a: int) -> fn (x: int) -> a + x);
let _ = print_int (named $N 0 + param $N 0 + dict $N 0 + vec_get v 0 + folded);
let _ = exit 0;
EOF

# --- the floor: the same count of PARTIAL applications, which must still cost.
cat > "$d/slow.mere" <<EOF
let add = fn (a: int) -> fn (b: int) -> a + b;
let rec go = fn (i: int) -> fn (acc: int) ->
  if i == 0 then acc
  else
    let half = add i in          // one argument only: a closure has to exist
    go (i - 1) (acc + half 1);
let _ = print_int (go $N 0);
let _ = exit 0;
EOF

fast=$(alloc "$d/fast.mere")
slow=$(alloc "$d/slow.mere")

printf 'closure_alloc_pin: saturated %s B (ceiling %s), partial %s B (floor %s)\n' \
  "$fast" "$CEILING" "$slow" "$FLOOR"

if [ "$fast" -lt 0 ] 2>/dev/null || [ -z "$fast" ]; then
  echo "  FAIL saturated: could not measure"; fail=1
elif [ "$fast" -gt "$CEILING" ]; then
  echo "  FAIL saturated: $fast B allocated, over the ceiling $CEILING."
  echo "       A saturated two-argument call is building the intermediate"
  echo "       closure's environment again -- fn2 is not being reached."
  fail=1
fi

if [ "$slow" -lt 0 ] 2>/dev/null || [ -z "$slow" ]; then
  echo "  FAIL partial: could not measure"; fail=1
elif [ "$slow" -lt "$FLOOR" ]; then
  echo "  FAIL partial: only $slow B allocated, under the floor $FLOOR."
  echo "       Either the fallback path is gone, or this program stopped"
  echo "       partially applying anything -- and then this gate has been"
  echo "       measuring nothing. Read the program before raising the floor."
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "closure_alloc_pin: ok"
