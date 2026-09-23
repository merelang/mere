#!/bin/sh
# scripts/wasm_assert_strength.sh -- the Wasm substring assertions must be
# capable of failing, and the exemption from that must stay small.
#
# Q-133. `test/test_basic.ml` checks the Wasm backend by compiling a small
# program and asserting that some string appears in the emitted module. That is
# only a check if the string would be ABSENT from a program without the feature,
# and 41 of the 97 were not: the module carries the whole runtime -- 58
# `$__lang_*` functions for the program `0` -- so a needle naming an opcode
# matched whatever was compiled.
#
# ⚠ AND ELEVEN OF THEM WERE FALSE, where the record said none were. Asked about
# the USER'S code instead of the module, `i32.mul` was `i64.mul`, `i32.eq` was
# `i64.eq`, and `i32.and` was nothing at all -- survivors of the i32→i64
# widening. The earlier sweep missed them because it only asked what was false
# MODULE-WIDE, and module-wide they were all true.
#
# WHERE THE CHECK LIVES NOW. In the test, not here. `assert_wasm` compiles the
# control program once and refuses a needle that also appears in the control's
# own code, so a vacuous assertion fails the moment it is written. Keeping a
# second copy of "what counts as the program's own code" in this script would be
# the same rule in two languages, and they would drift.
#
# WHAT IS LEFT FOR THIS SCRIPT is the shape of the population, which the test
# cannot see: how many assertions there are, how many took the skeleton
# exemption, and whether any have been written in the old unchecked form.
#
#   sh scripts/wasm_assert_strength.sh
#   sh scripts/wasm_assert_strength.sh --poison
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$ROOT/test/test_basic.ml}"
[ -f "$SRC" ] || { echo "wasm_assert_strength: no $SRC" >&2; exit 2; }
MODE="${1:-}"
fail=0

# ⚠ A FLOOR, because the failure that hides everything is the population going
# to zero. The first version of this script counted `assert_contains "wasm:`;
# when those were all renamed it reported "0 assertions, 0 vacuous" and exited
# GREEN. A denominator nobody guards is not a measurement.
TOTAL_FLOOR="${TOTAL_FLOOR:-90}"
EXEMPT_CEILING="${EXEMPT_CEILING:-12}"

n_all=$(grep -c 'assert_wasm\(_module\)\? "wasm:' "$SRC" || true)
n_exempt=$(grep -c 'assert_wasm_module "wasm:' "$SRC" || true)
n_old=$(grep -c 'assert_contains "wasm:' "$SRC" || true)

if [ "$n_all" -ge "$TOTAL_FLOOR" ]; then
  printf '  ok    %s\n' "$n_all wasm assertions (floor $TOTAL_FLOOR)"
else
  printf '  FAIL  %s\n' "only $n_all wasm assertions, below the floor of $TOTAL_FLOOR — the population shrank"
  fail=1
fi

if [ "$n_exempt" -le "$EXEMPT_CEILING" ]; then
  printf '  ok    %s\n' "$n_exempt take the skeleton exemption (ceiling $EXEMPT_CEILING)"
else
  printf '  FAIL  %s\n' "$n_exempt skeleton exemptions, above $EXEMPT_CEILING — the way out is widening"
  fail=1
fi

# The old form takes no control and cannot be vacuous-checked. It is the shape
# the 41 were written in.
if [ "$n_old" = "0" ]; then
  printf '  ok    %s\n' "none are written as a bare \`assert_contains\`, so every one is checked against the control"
else
  printf '  FAIL  %s\n' "$n_old wasm assertions still use \`assert_contains\`, which does not ask the control"
  fail=1
fi

if [ "$MODE" = "--poison" ]; then
  pfail=0
  # POISON 1: an impossible floor must refuse.
  if TOTAL_FLOOR=99999 sh "$0" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "POISON 1: an impossible floor still passed"; pfail=1
  else
    printf '  ok    %s\n' "POISON 1 (impossible floor): the population count can refuse"
  fi
  # POISON 2: the old unchecked form must be detected. A copy of the source with
  # one added is the poison -- the real file is not touched.
  T=$(mktemp -d)
  { cat "$SRC"; printf '\nlet _ = assert_contains "wasm: poisoned" (wasm "0") "(module";\n'; } > "$T/poisoned.ml"
  if SRC="$T/poisoned.ml" sh "$0" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "POISON 2: a bare assert_contains was not noticed"; pfail=1
  else
    printf '  ok    %s\n' "POISON 2 (one written the old way): noticed"
  fi
  rm -rf "$T"
  # POISON 3: ⚠ the vacuity check itself lives in the test. Prove it is wired by
  # showing the test file asks the control -- if that call vanished, every
  # assertion would silently stop being checked and this script could not tell.
  if grep -q 'wasm_control_user' "$SRC" && grep -q 'contains wasm_control_user needle' "$SRC"; then
    printf '  ok    %s\n' "POISON 3: the test still compares every needle against the control"
  else
    printf '  FAIL  %s\n' "POISON 3: the test no longer compares needles against the control — the checking moved or died"
    pfail=1
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "wasm_assert_strength --poison: ok (the gate can go red)"
  else
    echo "wasm_assert_strength --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "wasm_assert_strength: ok"; else echo "wasm_assert_strength: FAILED"; fi
exit "$fail"
