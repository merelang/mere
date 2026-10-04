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
# v0.1.501: no `grep -v '^()$'` on these. It dropped the unit line every Mere
# program used to print for its own value, which Q-136 removed at the source in
# v0.1.494 -- and it would also have dropped a `()` a program PRINTED, which is
# a difference this gate exists to see.
"$TMP/ref" > "$TMP/ref.out"
"$MERE" "$P" > "$TMP/interp.out" 2>&1
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

# The decimal conversions, same shape: the C binary is strtod/printf, the RV32I
# binary is the digit arrays, and the outputs must match byte for byte.
CV="$ROOT/test/float/rv_float_conv.mere"
"$MERE" -c "$CV" > "$TMP/cv.c" 2>"$TMP/err" || { echo "FAIL rv_float: the C backend refused the conversion gate"; exit 1; }
$CC -O2 -w -o "$TMP/cvref" "$TMP/cv.c" || exit 1
"$TMP/cvref" > "$TMP/cvref.out"
# --ram 64: each conversion builds exact digit arrays (a full-range double is
# ~700 digits) and a region reclaims nothing on this backend, so three hundred
# of them genuinely need tens of MB. 32 ran out at pattern 22.
"$MERE" -rv --ram 64 "$CV" > "$TMP/prog.bin" 2>"$TMP/err" || {
  echo "FAIL rv_float: -rv refused the conversion gate"; head -3 "$TMP/err"; exit 1; }
( cd "$TMP" && perl -e 'alarm 900; exec @ARGV' ./rvrun 64 2>&1 ) | grep -v '^rvrun: ' > "$TMP/cvrv.out"
CVN=$(grep -c . "$TMP/cvref.out")
if diff -q "$TMP/cvref.out" "$TMP/cvrv.out" >/dev/null; then
  echo "ok rv_float: $CVN conversions identical — float_of_str/str_of_float on RV32I equal strtod/printf"
else
  echo "FAIL rv_float: a decimal conversion on RV32I disagrees with the hardware"
  diff "$TMP/cvref.out" "$TMP/cvrv.out" | head -30
  rc=1
fi

# RV64 (v0.1.608): a double is one 64-bit word there and the arithmetic is the
# same algorithm on words instead of limbs. The same 3440 operations must give
# the hardware's bits, and a random sweep must too (a both-NaN line compared
# only as "both NaN"). Needs the 64-bit core from the same MEMU checkout.
if [ -f "$MEMU/riscv-runc/rv64i_run.mere" ]; then
  "$MERE" -c "$MEMU/riscv-runc/rv64i_run.mere" > "$TMP/rvrun64.c" 2>"$TMP/err" \
    && $CC -O2 -w -o "$TMP/rvrun64" "$TMP/rvrun64.c" \
    || { echo "FAIL rv_float: the RV64 emulator did not build"; exit 1; }
  "$MERE" -rv64 --ram 16 "$P" > "$TMP/prog.bin" 2>"$TMP/err" || { echo "FAIL rv_float: -rv64 refused the program"; exit 1; }
  ( cd "$TMP" && perl -e 'alarm 300; exec @ARGV' ./rvrun64 16 2>&1 ) | grep -v '^rvrun: ' > "$TMP/rv64.out"
  if diff -q "$TMP/ref.out" "$TMP/rv64.out" >/dev/null; then
    echo "ok rv_float: $CASES lines identical on RV64 — the one-word arithmetic equals the machine's doubles"
  else
    echo "FAIL rv_float: RV64's float arithmetic disagrees with the machine's doubles"
    diff "$TMP/ref.out" "$TMP/rv64.out" | head -20
    rc=1
  fi
  # the decimal conversions at 64 bits (v0.1.612: Dragon4 and a bignum parser on
  # words): the same conversion gate as RV32's above, and a random sweep
  for DC in "$CV" "$ROOT/test/float/rv_dec64.mere"; do
    "$MERE" -c "$DC" > "$TMP/dc.c" 2>"$TMP/err" && $CC -O1 -w -o "$TMP/dcref" "$TMP/dc.c" || { echo "FAIL rv_float: the C reference for $(basename "$DC") did not build"; exit 1; }
    "$TMP/dcref" > "$TMP/dcref.out"
    "$MERE" -rv64 --ram 64 "$DC" > "$TMP/prog.bin" 2>"$TMP/err" || { echo "FAIL rv_float: -rv64 refused $(basename "$DC")"; exit 1; }
    ( cd "$TMP" && perl -e 'alarm 600; exec @ARGV' ./rvrun64 64 2>&1 ) | grep -v '^rvrun: ' > "$TMP/dc64.out"
    DCN=$(grep -c . "$TMP/dcref.out")
    if diff -q "$TMP/dcref.out" "$TMP/dc64.out" >/dev/null; then
      echo "ok rv_float: $DCN lines of $(basename "$DC") identical on RV64 — str_of_float / float_of_str on words equal printf / strtod"
    else
      echo "FAIL rv_float: $(basename "$DC") on RV64 disagrees with printf / strtod"
      diff "$TMP/dcref.out" "$TMP/dc64.out" | head -10
      rc=1
    fi
  done
  FZ="$ROOT/test/float/rv_float_fuzz.mere"
  "$MERE" -c "$FZ" > "$TMP/fz.c" 2>"$TMP/err" && $CC -O1 -w -o "$TMP/fzref" "$TMP/fz.c" || { echo "FAIL rv_float: the fuzz reference did not build"; exit 1; }
  "$TMP/fzref" > "$TMP/fzref.out"
  "$MERE" -rv64 --ram 32 "$FZ" > "$TMP/prog.bin" 2>"$TMP/err" || { echo "FAIL rv_float: -rv64 refused the fuzz"; exit 1; }
  ( cd "$TMP" && perl -e 'alarm 300; exec @ARGV' ./rvrun64 32 2>&1 ) | grep -v '^rvrun: ' > "$TMP/fz64.out"
  # a line is "hi lo" (a double) or one int; two NaN doubles compare equal here
  bad=$(paste -d' ' "$TMP/fzref.out" "$TMP/fz64.out" | awk '
    function isnan(h, l) { return int(h / 1048576) % 2048 == 2047 && (h % 1048576 != 0 || l != 0) }
    NF == 4 { if ($1 != $3 || $2 != $4) { if (!(isnan($1, $2) && isnan($3, $4))) n++ } ; next }
    NF == 2 { if ($1 != $2) n++ ; next }
    { n++ }
    END { print n + 0 }')
  FZN=$(grep -c . "$TMP/fzref.out")
  if [ "$bad" = 0 ] && [ "$(grep -c . "$TMP/fz64.out")" = "$FZN" ]; then
    echo "ok rv_float: $FZN random-operand results identical on RV64 (two-NaN lines compared as NaN)"
  else
    echo "FAIL rv_float: $bad of $FZN random-operand results differ on RV64"
    paste -d' ' "$TMP/fzref.out" "$TMP/fz64.out" | awk '$1 != $3 || $2 != $4' | head -10
    rc=1
  fi
fi

# f_pow / exp / log: prelude Mere here, libm on the reference. Not required to
# agree everywhere (nobody's pow is required to be correctly rounded), so the
# file holds points where they DO agree and did not before v0.1.606 -- see its
# header for the sweep they were picked from.
LM="$ROOT/test/float/rv_libm_points.mere"
"$MERE" -c "$LM" > "$TMP/lm.c" 2>"$TMP/err" || { echo "FAIL rv_float: the C backend refused the libm points"; exit 1; }
$CC -O1 -w -o "$TMP/lmref" "$TMP/lm.c" -lm || exit 1
"$TMP/lmref" > "$TMP/lmref.out"
"$MERE" -rv --ram 32 "$LM" > "$TMP/prog.bin" 2>"$TMP/err" || {
  echo "FAIL rv_float: -rv refused the libm points"; head -3 "$TMP/err"; exit 1; }
( cd "$TMP" && perl -e 'alarm 300; exec @ARGV' ./rvrun 32 2>&1 ) | grep -v '^rvrun: ' > "$TMP/lmrv.out"
LMN=$(grep -c . "$TMP/lmref.out")
if diff -q "$TMP/lmref.out" "$TMP/lmrv.out" >/dev/null; then
  echo "ok rv_float: $LMN f_pow/exp/log points identical — the RV32I prelude equals libm on each"
else
  echo "FAIL rv_float: f_pow/exp/log on RV32I left libm's answer at a point it used to match"
  diff "$TMP/lmref.out" "$TMP/lmrv.out" | head -20
  rc=1
fi

# The libm (lib/rv_libm.ml): sin/cos/tan/atan2 and the twenty-one libm-named
# externs the RISC-V backend binds to it, against the CORRECTLY ROUNDED values
# in rv_libm_ext.expected -- not against this host's libm, which differs by
# platform (see the .mere's header). RV32 needs the full 256 MB: every float
# operation there allocates its limbs and a region gives nothing back.
LX="$ROOT/test/float/rv_libm_ext.mere"
LXE="$ROOT/test/float/rv_libm_ext.expected"
LXN=$(grep -c . "$LXE")
for w in 64 32; do
  if [ $w = 64 ]; then flag=-rv64; ram=64; run=./rvrun64; else flag=-rv; ram=256; run=./rvrun; fi
  [ -x "$TMP/${run#./}" ] || continue
  "$MERE" $flag --ram $ram "$LX" > "$TMP/prog.bin" 2>"$TMP/err" || {
    echo "FAIL rv_float: $flag refused the libm program"; head -3 "$TMP/err"; rc=1; continue; }
  ( cd "$TMP" && perl -e 'alarm 600; exec @ARGV' $run $ram 2>&1 ) | grep -v '^rvrun: ' > "$TMP/lx$w.out"
  if diff -q "$LXE" "$TMP/lx$w.out" >/dev/null; then
    echo "ok rv_float: $LXN libm results on RV$w identical to the correctly rounded values"
  else
    echo "FAIL rv_float: the libm on RV$w left the correctly rounded value"
    diff "$LXE" "$TMP/lx$w.out" | head -10
    rc=1
  fi
done
exit $rc
