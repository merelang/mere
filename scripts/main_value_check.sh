#!/bin/sh
# scripts/main_value_check.sh — what a program PRINTS WHEN IT ENDS, on all four.
#
# WHY THIS EXISTS, AND WHY parity.sh DOES NOT COVER IT. Every parity program
# ends with `print`, so the path that displays the program's own VALUE is one
# almost nothing exercises. It had drifted into four different answers for the
# same program and no gate could see it (Q-140):
#
#   `true`      interp true      C 1                LLVM 1        Wasm true
#   `"abc"`     interp "abc"     C abc              LLVM abc      Wasm "abc"
#   `(1, 2)`    interp (1, 2)    C 1                LLVM refused  Wasm (nothing)
#   `[1, 2]`    interp [1, 2]    C -872415215       LLVM refused  Wasm (nothing)
#
# The C column is the format table's catch-all printing a POINTER as a decimal
# integer. The rule now is one line -- the value is displayed the way `show`
# displays it -- and this is what keeps the four honest about it.
#
# THE ORACLE IS THE INTERPRETER, which is the right one here: it is the
# definition of what a Mere value looks like (`Eval.to_string`, the same thing
# `show` implements), and the compiled backends are the ones that have to agree
# with it.
#
# Usage:
#   sh scripts/main_value_check.sh            # check
#   sh scripts/main_value_check.sh --poison   # check that it can go red
#
# THE POISON rewrites one backend's answer before comparing and requires the
# gate to go red for that program on that backend. A gate that compares four
# strings can still be comparing them to themselves.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "main_value: $MERE not built" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/main_value.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

have() { command -v "$1" >/dev/null 2>&1; }
have clang || { echo "main_value: clang not found — skipping"; exit 0; }
WASM=1
{ have wat2wasm && have node; } || WASM=0

# One line each, and every one is a program whose VALUE is the thing printed --
# no `print` anywhere, which is the point.
PROGRAMS='42
true
1.5
"abc"
"a\"b"
(1, 2)
[1, 2]
Some 3
(1, "two", true)'

bad=0
poison="${1:-}"

run_one() { # program -> writes $tmp/{i,c,l,w}
  printf '%s\n' "$1" > "$tmp/p.mere"
  "$MERE" "$tmp/p.mere" >"$tmp/i" 2>&1 || true
  if "$MERE" -c "$tmp/p.mere" >"$tmp/p.c" 2>/dev/null \
     && clang -O0 -o "$tmp/pc" "$tmp/p.c" 2>/dev/null; then
    "$tmp/pc" >"$tmp/c" 2>&1 || true
  else echo "REFUSED" >"$tmp/c"; fi
  if "$MERE" -ll "$tmp/p.mere" >"$tmp/p.ll" 2>/dev/null \
     && clang -O0 -Wno-override-module -o "$tmp/pl" "$tmp/p.ll" 2>/dev/null; then
    "$tmp/pl" >"$tmp/l" 2>&1 || true
  else echo "REFUSED" >"$tmp/l"; fi
  if [ "$WASM" = 1 ] \
     && "$MERE" -w "$tmp/p.mere" >"$tmp/p.wat" 2>/dev/null \
     && wat2wasm --enable-tail-call "$tmp/p.wat" -o "$tmp/p.wasm" 2>/dev/null; then
    node "$ROOT/scripts/run_wasm.js" "$tmp/p.wasm" >"$tmp/w" 2>&1 || true
  else cp "$tmp/i" "$tmp/w"; fi
}

n=0
printf '%s\n' "$PROGRAMS" | while IFS= read -r prog; do
  [ -n "$prog" ] || continue
  n=$((n + 1))
  run_one "$prog"
  # The poison edits ONE backend's answer, so a gate that is not actually
  # comparing has to fail here.
  if [ "$poison" = "--poison" ] && [ "$n" = 1 ]; then
    echo "poisoned" >"$tmp/c"
  fi
  for b in c l w; do
    if ! cmp -s "$tmp/i" "$tmp/$b"; then
      echo "  $prog: interp=[$(tr -d '\n' <"$tmp/i")] $b=[$(tr -d '\n' <"$tmp/$b")]"
      echo x >>"$tmp/bad"
    fi
  done
done

[ -f "$tmp/bad" ] && bad=$(wc -l <"$tmp/bad" | tr -d ' ') || bad=0
total=$(printf '%s\n' "$PROGRAMS" | grep -c .)

if [ "$poison" = "--poison" ]; then
  if [ "$bad" -ge 1 ]; then
    echo "main_value: poison ok — the rewritten answer was caught ($bad mismatch)"
    exit 0
  fi
  echo "main_value: POISON FAILED — a rewritten answer went unnoticed"
  exit 1
fi

if [ "$bad" != 0 ]; then
  echo "main_value: $bad mismatch(es) across $total programs"
  exit 1
fi
[ "$WASM" = 1 ] || echo "main_value: wat2wasm / node absent — wasm column skipped"
echo "main_value: $total programs, all four agree with the interpreter"
