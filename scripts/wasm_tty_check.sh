#!/bin/sh
# scripts/wasm_tty_check.sh -- read_key and the terminal builtins on Wasm
# against C (v0.1.671).
#
# The Node host does the terminal with `stty` on the stdin it inherited, with
# the flags the C runtime clears: raw is -icanon -echo -iexten -ixon -ixoff,
# min 1 time 0, and tty_no_signal_keys is -isig. (Node's setRawMode is
# cfmakeraw, which takes Ctrl-C away as well -- the trade tty_raw does NOT make.)
# So the question is the one llvm_stdin_check asks of LLVM: after each call,
# does `stty -g` read back what it reads back after the C program's call? Under
# a pipe they do nothing, which is why the parity corpus cannot see them.
#
# --poison: the host's raw mode leaves IEXTEN alone. The terminal must differ.
#
# Usage: sh scripts/wasm_tty_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "wasm_tty: $MERE not found -- run 'dune build'" >&2; exit 1; }
for t in wat2wasm node python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL wasm_tty: no $t"; exit 1; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# the host, copied so the poison can change it without touching the tree
mkdir -p "$T/host"; cp "$ROOT"/scripts/*.js "$T/host/"
if [ "${1:-}" = --poison ]; then
  sed 's/\["-icanon", "-echo", "-iexten", /["-icanon", "-echo", /' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
  cmp -s "$ROOT/scripts/run_wasm.js" "$T/host/run_wasm.js" && { echo "FAIL wasm_tty --poison: the poison did not apply"; exit 1; }
fi

cat > "$T/k.mere" <<'MEOF'
let a = read_key ();
let b = read_key ();
let c = read_key ();
print ("[" ++ a ++ "][" ++ b ++ "][" ++ c ++ "]")
MEOF
cat > "$T/t.mere" <<'MEOF'
let _ = run "stty -g";
let _ = tty_raw ();
let _ = run "stty -g";
let _ = tty_no_signal_keys ();
let _ = run "stty -g";
let _ = tty_restore ();
let _ = run "stty -g";
print "end"
MEOF
for p in k t; do
  "$MERE" -c "$T/$p.mere" > "$T/$p.c" && "$CC" -w -O1 "$T/$p.c" -o "$T/${p}c" -lm \
    || { echo "FAIL wasm_tty: the C reference for $p did not build"; exit 1; }
  "$MERE" -w "$T/$p.mere" > "$T/$p.wat" && wat2wasm --enable-tail-call --enable-threads "$T/$p.wat" -o "$T/$p.wasm" \
    || { echo "FAIL wasm_tty: $p did not build as Wasm"; exit 1; }
done
fail=0
for inp in 'xy' 'q' ''; do
  c=$(printf "$inp" | "$T/kc" 2>&1); w=$(printf "$inp" | node "$T/host/run_wasm.js" "$T/k.wasm" 2>&1)
  [ "$c" = "$w" ] || { [ "${1:-}" = --poison ] || echo "  FAIL  read_key input [$inp]: C [$c] Wasm [$w]"; fail=1; }
done
pty() { python3 -c 'import pty, sys; pty.spawn(sys.argv[1:])' "$@" < /dev/null 2>&1 | tr -d '\r'; }
c=$(pty "$T/tc"); w=$(pty node "$T/host/run_wasm.js" "$T/t.wasm")
case "$c" in *:*) ;; *) echo "FAIL wasm_tty: stty under the pseudo-terminal said [$c]"; exit 1 ;; esac
tbad=0; [ "$c" = "$w" ] || tbad=1
if [ "${1:-}" = --poison ]; then
  [ "$tbad" = 1 ] && { echo "wasm_tty --poison: ok (a raw mode that keeps IEXTEN goes red)"; exit 0; }
  echo "wasm_tty --poison: POISON PASSED -- the terminal check cannot see IEXTEN"; exit 1
fi
[ "$tbad" = 0 ] || { printf '  FAIL  tty: C\n%s\n  Wasm\n%s\n' "$c" "$w"; fail=1; }
[ "$fail" = 0 ] || { echo "FAIL wasm_tty"; exit 1; }
echo "wasm_tty: ok (read_key agrees with C on 3 inputs; tty_raw, tty_no_signal_keys and tty_restore leave the terminal as C's do)"
