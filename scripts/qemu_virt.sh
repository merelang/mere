#!/bin/sh
# scripts/qemu_virt.sh — boot the RV32I backend's output on somebody else's machine.
#
# Builds the `examples/riscv_virt_*.mere` programs for QEMU's `virt` board, runs
# each one under `qemu-system-riscv32`, and diffs the UART output against what it
# is expected to print.
#
# Why this exists: the bare-metal stack in this repo is self-written at every
# layer — the compiler, the backend, and the emulator it usually runs on. So
# "our emulator agrees with our binary" is not evidence. QEMU is an independent
# implementation of the same specification, which makes it the only thing here
# that can tell a wrong binary from a wrong emulator. It checks:
#
#   * instruction encodings, against a decoder nobody here wrote
#   * the layout `_start` builds, at a load base above 2GB
#   * the 16550 UART protocol, against a real device model
#   * the trap contract: mtvec, mstatus.MIE, mie.MTIE, the CLINT's compare
#     register, and the PC the handler returns for mepc
#
# Set MEMU to a checkout of the memu project and each image is run on *both*
# machines — QEMU and the Mere-written emulator — and their output diffed. That
# turns this from "the binary behaves as expected" into a differential test
# between two independent implementations of the same board.
#
# Skips (exit 0) when qemu-system-riscv32 is absent, so it can be wired into a
# build without making QEMU a dependency.
#
# Usage:
#   sh scripts/qemu_virt.sh
#   MEMU=/path/to/memu sh scripts/qemu_virt.sh     # also diff against our own
#
# Prerequisites: dune-built _build/default/bin/mere.exe, qemu-system-riscv32
#   (macOS: brew install qemu, Debian/Ubuntu: apt install qemu-system-misc)

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}
QEMU=${QEMU:-qemu-system-riscv32}

if ! command -v "$QEMU" >/dev/null 2>&1; then
  echo "qemu_virt: $QEMU not found — skipping (this check is optional)"
  exit 0
fi

if [ ! -x "$MERE" ]; then
  echo "qemu_virt: $MERE not found — run dune build first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# Our own emulator, built once, if a memu checkout was pointed at. It reads
# `prog.bin` from the working directory and takes the RAM size plus `virt` for
# the board's layout.
RVRUN=""
if [ -n "$MEMU" ] && [ -f "$MEMU/riscv-runc/rv32i_run.mere" ]; then
  if "$MERE" -c "$MEMU/riscv-runc/rv32i_run.mere" > "$TMP/rvrun.c" 2>/dev/null \
     && cc -O2 -w "$TMP/rvrun.c" -o "$TMP/rvrun" 2>/dev/null; then
    RVRUN="$TMP/rvrun"
    echo "qemu_virt: cross-checking against the Mere emulator in \$MEMU"
  else
    echo "qemu_virt: could not build the Mere emulator from \$MEMU — QEMU only" >&2
  fi
fi
if [ -z "$RVRUN" ]; then
  # A gate that checks half of what it can check, and reports the same line
  # either way, reads as having checked all of it. The claim this half carries
  # is the whole point of the RISC-V arc -- that the same bytes behave
  # identically on QEMU and on a CPU written in Mere -- so its absence is said
  # out loud, next to the pass count and not only here.
  echo "qemu_virt: the Mere emulator half is NOT running (set MEMU=<memu checkout>)"
fi

# Run one image and diff its output. QEMU stops on its own: each program writes
# 0x5555 to virt's test finisher at 0x00100000 to power the machine off. The
# timeout is a backstop for a program that never gets there — without one, a
# broken image hangs the script instead of failing it.
check() {
  src=$1
  expected=$2
  name=$(basename "$src" .mere)
  bin="$TMP/$name.bin"

  "$MERE" -rv --bare --load-base 0x80000000 --ram 8 "$src" > "$bin"

  # `alarm` rather than timeout(1), which is absent on macOS.
  got=$(perl -e 'alarm 30; exec @ARGV' \
    "$QEMU" -M virt -bios none -nographic -no-reboot -kernel "$bin" 2>&1 || true)

  if [ "$got" != "$expected" ]; then
    printf '  FAIL  %s (qemu)\n' "$name"
    printf '    expected:\n%s\n' "$expected" | sed 's/^/      /'
    printf '    got:\n%s\n' "$got" | sed 's/^/      /'
    fail=$((fail + 1))
    return
  fi

  # The same bytes on our own machine. Any disagreement here is one of the two
  # emulators being wrong, which is the whole reason to run both.
  if [ -n "$RVRUN" ]; then
    cp "$bin" "$TMP/prog.bin"
    ours=$(cd "$TMP" && perl -e 'alarm 300; exec @ARGV' ./rvrun 8 virt 2>&1 || true)
    if [ "$ours" != "$expected" ]; then
      printf '  FAIL  %s (memu disagrees with qemu)\n' "$name"
      printf '    qemu:\n%s\n' "$got" | sed 's/^/      /'
      printf '    memu:\n%s\n' "$ours" | sed 's/^/      /'
      fail=$((fail + 1))
      return
    fi
    printf '  ok    %s (%s bytes, identical on both)\n' \
      "$name" "$(wc -c < "$bin" | tr -d ' ')"
  else
    printf '  ok    %s (%s bytes)\n' "$name" "$(wc -c < "$bin" | tr -d ' ')"
  fi
  pass=$((pass + 1))
}

echo "qemu_virt: $($QEMU --version | head -1)"

check examples/riscv_virt_hello.mere 'hello from qemu virt
built at run time: 42
fib 20 = 6765
mtime advances'

check examples/riscv_virt_timer.mere 'tick 1
tick 2
tick 3
three ticks, stopping'

# The letters come one per switch rather than one per N iterations, so this is a
# function of the scheduler and not of how fast either machine's clock runs.
check examples/riscv_virt_sched.mere 'scheduling two tasks:
ABABABA
switched enough, stopping'

# The parenthetical is a CLAIM, so it only gets made when it is true. Saying
# "agreed on every image" next to a nonzero failure count was the first version
# of this line, and a summary that contradicts the rows above it is worse than
# no summary.
if [ -z "$RVRUN" ]; then
  echo "qemu_virt: $pass passed, $fail failed (QEMU only — the differential against our own CPU did not run)"
elif [ "$fail" -eq 0 ]; then
  echo "qemu_virt: $pass passed, $fail failed (QEMU and the Mere emulator agreed on every image)"
else
  echo "qemu_virt: $pass passed, $fail failed (both emulators ran; see the failures above)"
fi
[ "$fail" -eq 0 ]
