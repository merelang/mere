#!/bin/sh
# scripts/llvm_stdin_check.sh -- read_line / read_stdin on LLVM against C,
# with real bytes on stdin (v0.1.663); read_key / stdin_byte and the terminal
# builtins too (v0.1.669).
#
# LLVM refused both until 663; it reads descriptor 0 with read(2), one byte at
# a time for a line so that a read_stdin after it gets exactly the rest -- the
# answer C's buffered FILE gives. The parity harness gives a program no stdin,
# so this feeds four inputs: lines then the rest, one line without a newline,
# nothing, and a blank line in the middle.
#
# --poison: the same program with the LLVM line reader made to keep its
# newline must NOT agree with C, or the inputs do not test the line.
#
# Usage: sh scripts/llvm_stdin_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
LLVM_CC="${LLVM_CC:-clang}"
[ -x "$MERE" ] || { echo "llvm_stdin: $MERE not found -- run 'dune build'" >&2; exit 1; }
command -v "$LLVM_CC" >/dev/null 2>&1 || { echo "FAIL llvm_stdin: no $LLVM_CC"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/p.mere" <<'MEOF'
let a = read_line ();
let b = read_line ();
let c = read_stdin ();
let d = read_line ();
print ("[" ++ a ++ "][" ++ b ++ "][" ++ c ++ "][" ++ d ++ "]")
MEOF
"$MERE" -c "$T/p.mere" > "$T/p.c" && "$CC" -w -O1 "$T/p.c" -o "$T/c" -lm \
  || { echo "FAIL llvm_stdin: the C reference did not build"; exit 1; }
"$MERE" -ll "$T/p.mere" > "$T/p.ll" || { echo "FAIL llvm_stdin: mere -ll refused it"; exit 1; }
if [ "${1:-}" = --poison ]; then
  # the line reader stops AFTER storing the newline: `br i1 %nl, label %done`
  # becomes a jump that counts the byte first
  sed 's/  br i1 %nl, label %done, label %cont/  br label %cont/' "$T/p.ll" > "$T/q.ll"
  cmp -s "$T/p.ll" "$T/q.ll" && { echo "FAIL llvm_stdin --poison: the poison did not apply"; exit 1; }
  mv "$T/q.ll" "$T/p.ll"
fi
"$LLVM_CC" -w -O1 "$T/p.ll" -o "$T/l" -lm || { echo "FAIL llvm_stdin: the IR did not build"; exit 1; }
n=0; bad=0
for inp in 'one\ntwo\nrest\nmore' 'only' '' 'a\n\nb\n'; do
  n=$((n + 1))
  c=$(printf "$inp" | "$T/c" 2>&1); l=$(printf "$inp" | "$T/l" 2>&1)
  if [ "$c" != "$l" ]; then bad=$((bad + 1)); [ "${1:-}" = --poison ] || echo "  FAIL  input $n: C [$c] LLVM [$l]"; fi
done
if [ "${1:-}" = --poison ] && [ "$bad" = 0 ]; then
  echo "llvm_stdin --poison: POISON PASSED -- the inputs do not tell a line from a line with its newline"; exit 1
fi
[ "${1:-}" = --poison ] || [ "$bad" = 0 ] || { echo "FAIL llvm_stdin: $bad of $n inputs differ"; exit 1; }

# v0.1.669: read_key and stdin_byte from a pipe, and the terminal builtins
# under a pseudo-terminal. tty_raw / tty_no_signal_keys write a struct termios
# whose layout this backend takes from the host (host_abi_llvm), so what `stty
# -g` reads back after each must be what the C runtime's leaves -- byte for byte,
# on the same machine. Under a pipe they do nothing, which is why the parity
# corpus cannot see them.
cat > "$T/k.mere" <<'MEOF'
let a = read_key ();
let b = stdin_byte ();
let c = read_key ();
let d = read_key ();
print ("[" ++ a ++ "][" ++ str_of_int b ++ "][" ++ c ++ "][" ++ d ++ "]")
MEOF
cat > "$T/t.mere" <<'MEOF'
let _ = run "stty -g";
let _ = tty_raw ();
let _ = run "stty -g";
let _ = tty_no_signal_keys ();
let _ = run "stty -g";
let _ = tty_restore ();
let _ = run "stty -g";
print (str_of_int (stdin_byte ()))
MEOF
kbad=0; tbad=0
for prog in k t; do
  "$MERE" -c "$T/$prog.mere" > "$T/$prog.c" && "$CC" -w -O1 "$T/$prog.c" -o "$T/${prog}c" -lm \
    || { echo "FAIL llvm_stdin: the C reference for $prog did not build"; exit 1; }
  "$MERE" -ll "$T/$prog.mere" > "$T/$prog.ll" || { echo "FAIL llvm_stdin: mere -ll refused $prog"; exit 1; }
  if [ "${1:-}" = --poison ]; then
    # read_key keeps nothing it read; the raw mode leaves VMIN alone
    sed -e 's/  store i8 %b, ptr %s$/  store i8 63, ptr %s/' -e 's/  store i8 1, ptr %vmin$/  store i8 0, ptr %vmin/' \
      "$T/$prog.ll" > "$T/$prog.q"
    cmp -s "$T/$prog.ll" "$T/$prog.q" && { echo "FAIL llvm_stdin --poison: the poison did not apply to $prog"; exit 1; }
    mv "$T/$prog.q" "$T/$prog.ll"
  fi
  "$LLVM_CC" -w -O1 "$T/$prog.ll" -o "$T/${prog}l" -lm || { echo "FAIL llvm_stdin: the IR for $prog did not build"; exit 1; }
done
for inp in 'xy' 'q' ''; do
  n=$((n + 1))
  c=$(printf "$inp" | "$T/kc" 2>&1); l=$(printf "$inp" | "$T/kl" 2>&1)
  if [ "$c" != "$l" ]; then kbad=$((kbad + 1)); [ "${1:-}" = --poison ] || echo "  FAIL  keys input $n: C [$c] LLVM [$l]"; fi
done
command -v python3 >/dev/null 2>&1 || { echo "FAIL llvm_stdin: no python3 to open a pseudo-terminal"; exit 1; }
pty() { python3 -c 'import pty, sys; pty.spawn(sys.argv[1:])' "$1" < /dev/null 2>&1 | tr -d '\r'; }
c=$(pty "$T/tc"); l=$(pty "$T/tl")
case "$c" in *:*) ;; *) echo "FAIL llvm_stdin: stty under the pseudo-terminal said [$c]"; exit 1 ;; esac
[ "$(printf '%s\n' "$c" | sed -n 1p)" = "$(printf '%s\n' "$c" | sed -n 2p)" ] \
  && { echo "FAIL llvm_stdin: tty_raw changed nothing in C's terminal -- the check cannot see a layout"; exit 1; }
if [ "$c" != "$l" ]; then tbad=1; [ "${1:-}" = --poison ] || printf '  FAIL  tty: C\n%s\n  LLVM\n%s\n' "$c" "$l"; fi
if [ "${1:-}" = --poison ]; then
  [ "$kbad" -gt 0 ] && [ "$tbad" -gt 0 ] && { echo "llvm_stdin --poison: ok (lines $bad, keys $kbad, tty $tbad go red)"; exit 0; }
  echo "llvm_stdin --poison: POISON PASSED for the keys ($kbad) or the terminal ($tbad)"; exit 1
fi
[ "$kbad" = 0 ] && [ "$tbad" = 0 ] || { echo "FAIL llvm_stdin: keys $kbad, tty $tbad differ"; exit 1; }
echo "llvm_stdin: ok ($n inputs, read_line / read_stdin / read_key / stdin_byte agree with C; tty_raw, tty_no_signal_keys and tty_restore leave the terminal as C's do)"
