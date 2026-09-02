#!/bin/sh
# scripts/rvd_oracle_check.sh — hold `mere -rvd` to an independent disassembler.
#
# WHY THIS EXISTS. The RV32I/RV64 backend has gates on what it EMITS
# (scripts/parity.sh compares outputs, scripts/rv_exec_check.sh runs the code,
# scripts/qemu_virt.sh cross-checks against QEMU). The disassembler that READS
# that output had none. It is not part of any program's behaviour, so nothing
# went red when it fell behind the backend it exists to explain:
#
#   - f3=3 printed as "?" -- LD and SD, which are MOST of a 64-bit binary,
#     because every slot, cell and field access on the wide target is one of
#     them. 41.4% of the lines in a mere-ruby listing were unreadable.
#   - opcodes 0x1B and 0x3B were not decoded at all, so every addiw/addw/
#     mulw/divw fell through to `.word`.
#   - shift amounts were read as 5 bits and srli/srai was told apart by
#     f7 = 0, which on RV64 is part of the shift amount: `srli x, y, 32`
#     printed as `srai`. That one is worse than a "?" -- it is confidently
#     wrong, and a listing you cannot trust is not an instrument.
#
# The cost was paid in full: the width bug in the try_or record's save area
# (v0.1.401) had to be found by hand-decoding the same words the disassembler
# was supposed to print, because the listing was mostly question marks.
#
# THE ORACLE. riscv64-elf-objdump, which nobody here wrote. Same argument as
# qemu_virt.sh: a decoder we wrote agreeing with itself proves nothing about the
# encoding, so this backend's encodings get checked against an outside decoder
# before anything we own is believed.
#   brew install riscv64-elf-binutils               # riscv64-elf-objdump
#   apt-get install binutils-riscv64-linux-gnu      # riscv64-linux-gnu-objdump
#     (set OBJDUMP to whichever name the platform installed)
#
# WHAT IS COMPARED. Every instruction in the code region of a real binary --
# not a hand-picked handful, because the instructions that go stale are the ones
# no example uses. The code region ends where the debug map says the string
# blocks begin, so the rodata (which is data, and which BOTH sides are right to
# make nonsense of) is excluded rather than tolerated.
#
# Two comparisons, because they fail differently:
#   1. mnemonics, over everything -- catches "not decoded" and "decoded as the
#      wrong instruction"
#   2. full operands, over the load/store family -- catches a wrong offset or a
#      wrong base register, which is what a listing is READ for and what a
#      mnemonic-only check would pass while printing the wrong number
#
# A "?" or ".word" inside the code region is a FAILURE here, not a skip: the
# oracle decoded it, so it is an instruction, so this disassembler owes a name.
#
# THE WIDTHS ARE NOT INTERCHANGEABLE, and this gate was checked by breaking it:
# run against the pre-fix disassembler, all four 64-bit rows fail and name the
# LD/SD gap (585, 278, 296 and 8843 unnamed instructions) -- and all three
# 32-bit rows PASS. They have to: f3=3 is not an RV32 encoding, and a shift
# amount only needs six bits once the register is 64 wide. So the 32-bit column
# cannot stand in for the 64-bit one here; it is present to catch a future
# regression in what it does cover, not as evidence about the wide target.
#
# Usage:
#   sh scripts/rvd_oracle_check.sh
#   OBJDUMP=riscv64-elf-objdump sh scripts/rvd_oracle_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
OBJDUMP="${OBJDUMP:-riscv64-elf-objdump}"
[ -x "$MERE" ] || { echo "rvd_oracle: $MERE not found — run 'dune build'" >&2; exit 1; }

if ! command -v "$OBJDUMP" >/dev/null 2>&1; then
  # Named, not silent: a gate that prints its usual pass line whether or not it
  # ran is a gate that has stopped meaning what it says.
  echo "rvd_oracle: $OBJDUMP absent — skipping (brew install riscv64-elf-binutils, or"
  echo "            apt-get install binutils-riscv64-linux-gnu and set OBJDUMP)"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0; pass=0; fail=0; skip=0

# The programs to disassemble, chosen for instruction MIX rather than for what
# they compute: try_or_save_area for the unwind and the record offsets this gate
# was written after, arith for the M extension, bitwise for the shifts (where
# the 6-bit shamt and the bit-30 srai/srli discriminator live), float_edges for
# the injected softfloat, which is the largest body of shift-heavy code the
# backend ever emits. Cases the backend refuses are reported as skips below,
# so this list can name a program that only compiles at one width.
CASES="test/parity/try_or_save_area.mere test/parity/arith.mere test/parity/bitwise.mere test/parity/float_edges.mere"

for width in 32 64; do
  if [ "$width" = 64 ]; then flag=-rv64; gflag=-rv64g; arch=riscv:rv64
  else flag=-rv; gflag=-rvg; arch=riscv:rv32; fi
  for case in $CASES; do
    src="$ROOT/$case"
    [ -f "$src" ] || continue
    name="$(basename "$case" .mere):$width"
    # A case this backend refuses (math_demo wants sqrt; a 64-bit literal will
    # not fit at 32) is host_matrix.sh's business, not this gate's -- but it is
    # SAID, because a silently dropped case reads as a covered one.
    if ! "$MERE" $flag --ram 32 "$src" > "$TMP/prog.bin" 2>"$TMP/err"; then
      printf '  skip  %-28s %s\n' "$name" "$(head -1 "$TMP/err" | cut -c1-72)"
      skip=$((skip+1)); continue
    fi
    "$MERE" $gflag --ram 32 "$src" > "$TMP/prog.map" 2>/dev/null || {
      printf '  skip  %-28s no debug map\n' "$name"; skip=$((skip+1)); continue; }

    # The code region ends where the string blocks begin. The map names those
    # (`str_N`), so the boundary is read rather than guessed -- a "last function
    # + some slack" estimate reaches into rodata, and both disassemblers are
    # RIGHT to make nonsense of data. It made this gate report `fmadd.s` for the
    # one-character string literals "C", "G" and "K": 0x43, 0x47 and 0x4B are
    # both the ASCII codes and the F-extension opcodes, so the oracle named an
    # instruction from an extension this backend does not emit. A gate whose
    # subject includes data accuses the disassembler of the harness's mistake.
    # The runtime's own helpers are `__str_*`, hence the anchored match.
    end=$(awk '$1=="S" && $3 ~ /^str_/ {if (lo==0 || $2+0 < lo) lo=$2+0} END{print lo+0}' "$TMP/prog.map")
    if [ "$end" = 0 ]; then
      # a program with no string literals: code runs to the last function
      end=$(awk '$1=="F" && $2+0>lim {lim=$2+0} END{print lim+0}' "$TMP/prog.map")
    fi
    [ "$end" -gt 0 ] 2>/dev/null || { echo "  FAIL  $name: the map named neither a string block nor a function"; fail=$((fail+1)); rc=1; continue; }

    "$MERE" -rvd "$TMP/prog.bin" > "$TMP/mine.txt" 2>/dev/null
    # -D: disassemble ALL of a raw binary. no-aliases+numeric so the oracle does
    # not spell pseudo-instructions (this side does, and the comparison maps
    # them) and does not use ABI register names (this side does, likewise).
    "$OBJDUMP" -D -b binary -m "$arch" -M no-aliases,numeric "$TMP/prog.bin" > "$TMP/orc.txt" 2>/dev/null

    out=$(python3 "$ROOT/scripts/rvd_oracle_cmp.py" "$TMP/mine.txt" "$TMP/orc.txt" "$end")
    if [ $? -eq 0 ]; then
      printf '  ok    %-28s %s\n' "$name" "$out"; pass=$((pass+1))
    else
      printf '  FAIL  %-28s\n' "$name"; echo "$out" | sed 's/^/    /'; fail=$((fail+1)); rc=1
    fi
  done
done

if [ "$pass" = 0 ] && [ "$fail" = 0 ]; then
  echo "rvd_oracle: no program compiled for either width — nothing was compared"; exit 1
fi
echo "rvd_oracle: $pass passed, $fail failed, $skip skipped (mere -rvd vs $OBJDUMP)"
exit $rc
