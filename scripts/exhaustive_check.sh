#!/bin/sh
# scripts/exhaustive_check.sh — a `match` missing a named case is refused by
# every path that runs or emits the program, and the arm the error prints is
# valid Mere.
#
# THE FAILURE THIS EXISTS FOR. A missing case used to be a warning, and the
# warning was printed from inside `Pipeline.process` -- which is to say on the
# interpreter's path and nowhere else. `-c`, `-ll`, `-w` and `-rv` said nothing
# at all and exited 0: the four backends that produce the artifact were the four
# that never mentioned it. A `match` with no arm for a case has no value to
# return, so each backend invented one, and the answer came back wrong instead
# of refused. The edit that provokes this is the ordinary one -- a case added to
# a type, every `match` over it left as it was -- so the check has to be on the
# path the person or the agent is actually using.
#
# WHAT IT CHECKS.
#
#   1. REFUSAL, ON EVERY PATH. The same program, on interp / C / LLVM / Wasm /
#      RV32IM: nonzero status, and the word `non-exhaustive` in the output. A
#      path that builds it is the regression this gate is named after.
#
#   2. THE HINT IS VALID MERE, read back from the compiler rather than copied.
#      The `help:` line is cut out of the error, its `...` replaced with a body,
#      and the arm spliced into the program -- which must then build and run on
#      every backend and print the right answer. A hint nobody can paste is
#      worse than no hint, and asserting a remembered string here would not
#      notice the day the pattern syntax it prints stops parsing.
#
#   3. A NEGATIVE. The same program with every arm written is accepted and
#      silent on all five paths. Without this, a gate that refuses everything
#      passes items 1 and 2.
#
#   4. THE HOLE THE NOTE OFFERS. `| _ -> fail "todo"` builds and runs, on every
#      backend -- it is what the error tells people to write to keep compiling,
#      and `fail` is typed `'a` on the interpreter, which is not by itself a
#      promise that the compiled backends take it in an arm position.
#
#   5. THE ESCAPE HATCH. `--allow-nonexhaustive` builds the program in item 1
#      and says `warning` instead.
#
#   6. THE APPROXIMATE CHECK IS STILL A WARNING. `match n with | 0 -> ...` over
#      an int cannot name a missing case -- that arm of the checker is an
#      admitted approximation -- so it must not stop a build. Promoting it
#      would demand a `_` arm on every match over a scalar.
#
# The subject is integer-only so that all five backends, RV32IM included, can
# take it.
#
# Usage:
#   sh scripts/exhaustive_check.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}

if [ ! -x "$MERE" ]; then
  echo "exhaustive_check: $MERE not found — run dune build first" >&2
  exit 1
fi

CC=$(command -v clang || command -v cc || true)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
checked=0

# --- the subject, in three shapes ------------------------------------------
#
# `missing`: no arm for Triangle. `full`: the arm written by hand, which is the
# negative. `hole`: the arm the note offers.

cat > "$TMP/missing.mere" <<'EOF'
type shape = Circle of int | Square of int | Triangle of int * int;
let area = fn (s: shape) ->
  match s with
  | Circle r -> 3 * r * r
  | Square w -> w * w;
print (str_of_int (area (Square 3)))
EOF

cat > "$TMP/full.mere" <<'EOF'
type shape = Circle of int | Square of int | Triangle of int * int;
let area = fn (s: shape) ->
  match s with
  | Circle r -> 3 * r * r
  | Square w -> w * w
  | Triangle (b, h) -> b * h / 2;
print (str_of_int (area (Triangle (3, 4))))
EOF

cat > "$TMP/hole.mere" <<'EOF'
type shape = Circle of int | Square of int | Triangle of int * int;
let area = fn (s: shape) ->
  match s with
  | Circle r -> 3 * r * r
  | Square w -> w * w
  | _ -> fail "todo";
print (str_of_int (area (Square 3)))
EOF

cat > "$TMP/scalar.mere" <<'EOF'
let name = fn (n: int) ->
  match n with
  | 0 -> "zero"
  | 1 -> "one";
print (name 0)
EOF

# --- emit_ok <file> : does every backend accept it? ------------------------
#
# Emission, not execution, is the question for the backends: whether the
# program is refused is decided before any toolchain runs, and the LLVM / Wasm
# / RV legs need tools that a checkout may not have. Item 3 runs the C binary
# as well, where clang is present, so "accepted" is not only "emitted".

emit_ok() {
  file=$1; label=$2
  for flag in -c -ll -w -rv; do
    if "$MERE" $flag "$file" > "$TMP/emit.out" 2>"$TMP/emit.err"; then
      checked=$((checked + 1))
    else
      echo "FAIL $label: $flag refused a program that should build"
      sed -n '1,6p' "$TMP/emit.err"
      fail=1
    fi
  done
  if "$MERE" "$file" > "$TMP/emit.out" 2>"$TMP/emit.err"; then
    checked=$((checked + 1))
  else
    echo "FAIL $label: interp refused a program that should run"
    sed -n '1,6p' "$TMP/emit.err"
    fail=1
  fi
}

# --- 1. refusal, on every path --------------------------------------------

for flag in "" -c -ll -w -rv; do
  path_name=${flag:-interp}
  # shellcheck disable=SC2086
  "$MERE" $flag "$TMP/missing.mere" >"$TMP/r.out" 2>"$TMP/r.err"
  rc=$?
  out=$(cat "$TMP/r.out" "$TMP/r.err")
  checked=$((checked + 1))
  if [ "$rc" = 0 ]; then
    echo "FAIL refusal: $path_name exited 0 on a match with no arm for Triangle"
    fail=1
  elif ! printf '%s' "$out" | grep -q "non-exhaustive"; then
    echo "FAIL refusal: $path_name failed without saying why:"
    printf '%s\n' "$out" | sed -n '1,6p'
    fail=1
  elif ! printf '%s' "$out" | grep -q "Triangle"; then
    echo "FAIL refusal: $path_name refused without naming the missing case"
    fail=1
  fi
done

# --- 2. the hint is valid Mere --------------------------------------------
#
# Cut the arm out of the compiler's own output. A `help:` line that cannot be
# found is a FAIL and not a skip: this is the check that would otherwise pass
# by never running, and the anchor it needs is the thing most likely to move.

"$MERE" "$TMP/missing.mere" >/dev/null 2>"$TMP/hint.err"
arm=$(sed -n 's/^ *= *help: *//p' "$TMP/hint.err" | sed -n '1p')
checked=$((checked + 1))
if [ -z "$arm" ]; then
  echo "FAIL hint: no 'help:' line to read an arm from — the error's shape moved:"
  sed -n '1,12p' "$TMP/hint.err"
  fail=1
else
  # `| Triangle (a1, a2) -> ...` with a body in place of the placeholder. The
  # body uses both bound names, so an arm that binds the payload wrongly (one
  # name for a two-component tuple, say) fails to type here rather than
  # silently type-checking against an unused binding.
  body="a1 * a2"
  filled=$(printf '%s' "$arm" | sed "s|\\.\\.\\.|$body|")
  case $filled in
    *"$body"*) : ;;
    *)
      echo "FAIL hint: the arm carried no '...' placeholder to fill: $arm"
      fail=1
      ;;
  esac
  {
    sed '$d' "$TMP/missing.mere" | sed '$s/;$//'
    printf '  %s;\n' "$filled"
    printf 'print (str_of_int (area (Triangle (3, 4))))\n'
  } > "$TMP/pasted.mere"

  got=$("$MERE" "$TMP/pasted.mere" 2>"$TMP/pasted.err" | sed -n '1p')
  checked=$((checked + 1))
  if [ "$got" != "12" ]; then
    echo "FAIL hint: the arm the compiler printed does not run — got '$got', expected 12"
    echo "--- the program that was built from it ---"
    cat "$TMP/pasted.mere"
    sed -n '1,10p' "$TMP/pasted.err"
    fail=1
  fi
  emit_ok "$TMP/pasted.mere" "hint"
fi

# --- 3. the negative ------------------------------------------------------

emit_ok "$TMP/full.mere" "full"
got=$("$MERE" "$TMP/full.mere" 2>&1 | sed -n '1p')
checked=$((checked + 1))
[ "$got" = "6" ] || { echo "FAIL full: got '$got', expected 6"; fail=1; }

# Silent, not merely accepted: a build that prints the error and succeeds
# anyway is the state this gate was written to leave behind.
"$MERE" -c "$TMP/full.mere" >/dev/null 2>"$TMP/full.err"
checked=$((checked + 1))
if grep -q "non-exhaustive" "$TMP/full.err"; then
  echo "FAIL full: a match with every arm written was still reported:"
  sed -n '1,6p' "$TMP/full.err"
  fail=1
fi

if [ -n "$CC" ]; then
  if "$MERE" -c "$TMP/full.mere" > "$TMP/full.c" 2>/dev/null &&
     $CC -O1 -w "$TMP/full.c" -o "$TMP/full.bin" 2>/dev/null; then
    got=$("$TMP/full.bin" 2>&1 | sed -n '1p')
    checked=$((checked + 1))
    [ "$got" = "6" ] || { echo "FAIL full: the C binary printed '$got', expected 6"; fail=1; }
  else
    echo "FAIL full: the C backend did not build a program with every arm written"
    fail=1
  fi
fi

# --- 4. the hole the note offers ------------------------------------------

emit_ok "$TMP/hole.mere" "hole"
got=$("$MERE" "$TMP/hole.mere" 2>&1 | sed -n '1p')
checked=$((checked + 1))
[ "$got" = "9" ] || { echo "FAIL hole: got '$got', expected 9"; fail=1; }

if [ -n "$CC" ]; then
  if "$MERE" -c "$TMP/hole.mere" > "$TMP/hole.c" 2>/dev/null &&
     $CC -O1 -w "$TMP/hole.c" -o "$TMP/hole.bin" 2>/dev/null; then
    got=$("$TMP/hole.bin" 2>&1 | sed -n '1p')
    checked=$((checked + 1))
    [ "$got" = "9" ] || { echo "FAIL hole: the C binary printed '$got', expected 9"; fail=1; }
  else
    echo "FAIL hole: the C backend did not build the arm the note tells people to write"
    fail=1
  fi
fi

# --- 5. the escape hatch --------------------------------------------------

"$MERE" --allow-nonexhaustive "$TMP/missing.mere" >"$TMP/a.out" 2>"$TMP/a.err"
rc=$?
checked=$((checked + 1))
if [ "$rc" != 0 ]; then
  echo "FAIL allow: --allow-nonexhaustive still refused the program (exit $rc)"
  sed -n '1,8p' "$TMP/a.err"
  fail=1
elif ! grep -q "warning" "$TMP/a.err"; then
  echo "FAIL allow: --allow-nonexhaustive built it and said nothing"
  fail=1
elif grep -q "^error" "$TMP/a.err"; then
  echo "FAIL allow: --allow-nonexhaustive built it and still called it an error"
  fail=1
fi

"$MERE" --allow-nonexhaustive -c "$TMP/missing.mere" >/dev/null 2>"$TMP/a2.err"
rc=$?
checked=$((checked + 1))
[ "$rc" = 0 ] || { echo "FAIL allow: --allow-nonexhaustive did not reach the C backend (exit $rc)"; fail=1; }

# --- 6. the approximate check is still a warning --------------------------

for flag in "" -c; do
  path_name=${flag:-interp}
  # shellcheck disable=SC2086
  "$MERE" $flag "$TMP/scalar.mere" >/dev/null 2>"$TMP/s.err"
  rc=$?
  checked=$((checked + 1))
  if [ "$rc" != 0 ]; then
    echo "FAIL scalar: $path_name refused a match over an int, where the checker cannot name a case (exit $rc)"
    sed -n '1,8p' "$TMP/s.err"
    fail=1
  elif ! grep -q "no wildcard arm" "$TMP/s.err"; then
    echo "FAIL scalar: $path_name said nothing about a match over an int with no wildcard"
    fail=1
  fi
done

# --- verdict --------------------------------------------------------------
#
# A run that checked nothing is a failure: the subject moving out from under
# this file must not read as agreement with it.

if [ "$checked" -lt 20 ]; then
  echo "FAIL exhaustive_check: only $checked checks ran, expected at least 20"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "exhaustive_check: OK ($checked checks)"
else
  echo "exhaustive_check: FAILED ($checked checks)"
fi
exit "$fail"
