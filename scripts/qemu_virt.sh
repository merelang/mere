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
# Skips (exit 0) when qemu-system-riscv32 is absent, so it can be wired into a
# build without making QEMU a dependency.
#
# Usage:
#   sh scripts/qemu_virt.sh
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

  if [ "$got" = "$expected" ]; then
    printf '  ok    %s (%s bytes)\n' "$name" "$(wc -c < "$bin" | tr -d ' ')"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$name"
    printf '    expected:\n%s\n' "$expected" | sed 's/^/      /'
    printf '    got:\n%s\n' "$got" | sed 's/^/      /'
    fail=$((fail + 1))
  fi
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

echo "qemu_virt: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
