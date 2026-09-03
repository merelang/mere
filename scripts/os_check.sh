#!/bin/sh
# scripts/os_check.sh — the operating system on the CPU written in Mere, run.
#
# examples/riscv_bare_shell.mere (a kernel with two tasks and a shell),
# riscv_bare_user.mere + riscv_user_prog.mere (a kernel that loads a separately
# compiled, ordinary Mere program as a user process and answers its syscalls),
# and riscv_bare_selfhost.mere are the programs behind the sentence "an OS on a
# self-made CPU". Nothing ran them: the day a literal check arrived that
# refused their `0x80000007` interrupt cause, all three stopped compiling and no
# gate said so. This one builds them and runs two of them on memu's RV32 core.
#
# The shell's background counter and the kernel's tick count depend on how
# fast stdin arrives, so those numbers are not compared; every other line is.
#
#   MEMU=/path/to/memu sh scripts/os_check.sh
set -u
MERE=${MERE:-./_build/default/bin/mere.exe}
MEMU=${MEMU:-}
CC=${CC:-cc}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
[ -x "$MERE" ] || { echo "os_check: $MERE not found — run dune build first" >&2; exit 1; }
pass=0; fail=0

for ex in riscv_bare_shell riscv_bare_user riscv_bare_selfhost; do
  if "$MERE" -rv --bare "examples/$ex.mere" > "$TMP/$ex.bin" 2>"$TMP/$ex.err"; then
    printf '  ok    %s compiles (%s bytes)\n' "$ex" "$(wc -c < "$TMP/$ex.bin" | tr -d ' ')"; pass=$((pass+1))
  else
    printf '  FAIL  %s does not compile\n' "$ex"; head -2 "$TMP/$ex.err" | sed 's/^/    /'; fail=$((fail+1))
  fi
done

if [ -z "$MEMU" ] || [ ! -f "$MEMU/riscv-runc/rv32i_run.mere" ]; then
  echo "os_check: $pass built, $fail failed — set MEMU=<memu checkout> to also RUN them"
  [ "$fail" = 0 ] && exit 0 || exit 1
fi
if ! "$MERE" -c "$MEMU/riscv-runc/rv32i_run.mere" > "$TMP/rvrun.c" 2>"$TMP/err" \
   || ! $CC -O2 -w "$TMP/rvrun.c" -o "$TMP/rvrun" 2>"$TMP/err"; then
  echo "os_check: the emulator did not build; nothing ran"; head -2 "$TMP/err"; exit 1
fi

# 1. the shell: banner, the command list, a survived fault, a clean halt.
cp "$TMP/riscv_bare_shell.bin" "$TMP/prog.bin"
( cd "$TMP" && printf 'help\nfault\nhalt\n' | perl -e 'alarm 120; exec @ARGV' ./rvrun 2>/dev/null ) \
  | grep -a -v '^rvrun: ' > "$TMP/shell.out"
want='mere kernel, two tasks. type `help`.
mere> help
commands: help ticks bg faults echo peek fault halt
mere> fault
survived a fault
mere> halt
halted'
if [ "$(cat "$TMP/shell.out")" = "$want" ]; then
  echo "  ok    riscv_bare_shell runs (help, a survived fault, halt)"; pass=$((pass+1))
else
  echo "  FAIL  riscv_bare_shell output differs:"; printf '%s\n' "$want" > "$TMP/want.txt"; diff "$TMP/want.txt" "$TMP/shell.out" | head -8 | sed 's/^/    /'; fail=$((fail+1))
fi

# 2. a kernel and a user process compiled separately; the tick count is timing.
cp "$TMP/riscv_bare_user.bin" "$TMP/prog.bin"
if "$MERE" -rv --load-base 8388608 --ram 4 examples/riscv_user_prog.mere > "$TMP/user.bin" 2>"$TMP/uerr"; then
  ( cd "$TMP" && perl -e 'alarm 120; exec @ARGV' ./rvrun 16 2>/dev/null ) \
    | grep -a -v '^rvrun: ' | sed -E 's/ and [0-9]+ ticks/ and N ticks/' > "$TMP/user.out"
  want='kernel: starting a user process at 8MB
user: hello from a user process
user: I do not know a kernel exists
user: fib 20 = 6765
user: exiting
kernel: user process exited after 9 syscalls and N ticks'
  if [ "$(cat "$TMP/user.out")" = "$want" ]; then
    echo "  ok    riscv_bare_user + riscv_user_prog (a user process, 9 syscalls)"; pass=$((pass+1))
  else
    echo "  FAIL  kernel + user process output differs:"; printf '%s\n' "$want" > "$TMP/want.txt"; diff "$TMP/want.txt" "$TMP/user.out" | head -8 | sed 's/^/    /'; fail=$((fail+1))
  fi
else
  echo "  FAIL  riscv_user_prog does not compile"; head -2 "$TMP/uerr"; fail=$((fail+1))
fi

echo "os_check: $pass passed, $fail failed (the OS examples, built and run on the Mere-written CPU)"
[ "$fail" = 0 ]
