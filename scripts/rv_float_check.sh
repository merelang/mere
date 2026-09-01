#!/bin/sh
# scripts/rv_float_check.sh — our float arithmetic against the machine's.
#
# RV32I has no float unit and no 64-bit word, so `+` on two floats is a call into
# contrib/softfloat, which does it in 15-bit limbs. This runs the SAME program on
# a backend with hardware doubles and on RV32I, and requires identical output.
# Nothing here is an expectation somebody wrote down: the reference is whatever
# the machine's own doubles produce.
#
# test/float/rv_float_ops.mere prints BITS, as four 16-bit chunks, because
# `float_bits_hi` does not print the same on both sides -- it is unsigned 32-bit,
# and on a signed 32-bit int the same bits come out negative. Bits also mean -0.0
# and the NaN payloads are covered, which comparing values would let through.
#
# The RV32I half needs a 32-bit machine. `MEMU=<memu checkout>` supplies one and
# the differential runs; without it only the hardware half runs and this says so
# rather than printing ok. That is the hole scripts/softfloat_check.sh names in
# its own header: "checked by running the library on a 32-bit machine, which
# needs an emulator this repository does not depend on".
#
# Usage:
#   sh scripts/rv_float_check.sh
#   MEMU=/path/to/memu sh scripts/rv_float_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
P="$ROOT/test/float/rv_float_ops.mere"
[ -x "$MERE" ] || { echo "rv_float_check: $MERE not found — run 'dune build'" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

# The reference: the C backend, where a float is a C double and `+` is the
# machine's own add. The interpreter is checked against it too -- if those two
# disagree the reference itself is in question and the RV32I diff would be
# comparing against a moving target.
"$MERE" -c "$P" > "$TMP/ref.c" 2>"$TMP/err" || { echo "FAIL rv_float: the C backend refused the program"; head -5 "$TMP/err"; exit 1; }
$CC -O1 -w -o "$TMP/ref" "$TMP/ref.c" 2>"$TMP/err" || { echo "FAIL rv_float: cc refused the C backend's output"; head -5 "$TMP/err"; exit 1; }
"$TMP/ref" | grep -v '^()$' > "$TMP/ref.out"
"$MERE" "$P" | grep -v '^()$' > "$TMP/interp.out" 2>&1
if ! diff -q "$TMP/ref.out" "$TMP/interp.out" >/dev/null; then
  echo "FAIL rv_float: the interpreter and the C backend disagree — the reference is not stable"
  diff "$TMP/ref.out" "$TMP/interp.out" | head -10
  rc=1
fi
CASES=$(grep -c . "$TMP/ref.out")
SKIPPED=$(grep -c 'skipped' "$TMP/ref.out" || true)

# --ram 32: this program allocates a limb record per operand per operation, and
# 8MB is not enough for 2800 of them.
"$MERE" -rv --ram 32 "$P" > "$TMP/prog.bin" 2>"$TMP/err" || {
  echo "FAIL rv_float: -rv refused the program"; head -5 "$TMP/err"; exit 1; }

if [ -z "${MEMU:-}" ]; then
  echo "rv_float: $CASES lines agree between the interpreter and the C backend, and the RV32I image builds"
  echo "rv_float: the RV32I half did NOT run — set MEMU=<memu checkout> to compare our softfloat against the hardware"
  exit $rc
fi
[ -f "$MEMU/riscv-runc/rv32i_run.mere" ] || { echo "FAIL rv_float: no rv32i_run.mere under MEMU=$MEMU"; exit 1; }
"$MERE" -c "$MEMU/riscv-runc/rv32i_run.mere" > "$TMP/rvrun.c" 2>"$TMP/err" || {
  echo "FAIL rv_float: the emulator did not compile"; head -5 "$TMP/err"; exit 1; }
$CC -O2 -w -o "$TMP/rvrun" "$TMP/rvrun.c" || { echo "FAIL rv_float: cc refused the emulator"; exit 1; }
( cd "$TMP" && ./rvrun 32 ) 2>&1 | grep -v '^rvrun: ' > "$TMP/rv.out"

if diff -q "$TMP/ref.out" "$TMP/rv.out" >/dev/null; then
  echo "ok rv_float: $CASES lines identical — our softfloat on RV32I equals the machine's doubles ($SKIPPED unspecified NaN pairs excluded, and named in the output)"
else
  echo "FAIL rv_float: our softfloat disagrees with the machine's doubles"
  diff "$TMP/ref.out" "$TMP/rv.out" | head -20
  rc=1
fi
exit $rc
