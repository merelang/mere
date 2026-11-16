#!/bin/sh
# scripts/bracket_depth_check.sh — the emitted C must fit inside the C compiler's
# nesting limit, and every operand must be evaluated in the order the interpreter
# evaluated it.
#
# TWO QUESTIONS, ONE SHAPE. A chain of operators, of `&&`, or of `else if` used to be
# emitted as one nested expression: one bracket per link. clang stops at 256 of them
# (Apple's build allows far more, which is why this was invisible here for a year and
# fatal on the CI runner), and mere-ruby's prelude writes chains in the hundreds. The
# same nesting also left the ORDER of the operands to the C compiler, which does not
# fix one: clang runs them left to right, gcc right to left. v0.1.450 emits these as
# sequenced statement expressions and flat `else if`, which answers both.
#
# THE LIMIT IS ASKED, NOT COUNTED. Counting brackets in the emitted text gives a
# number that is not clang's number -- `({ })` and initializer braces are counted
# differently, and an earlier version of this work under-reported its own fix by
# reading its own counter. So the check is `clang -fsyntax-only -fbracket-depth=256`:
# the tool that would refuse is the tool that is asked. The probe with the depth set
# absurdly low is the armed-instrument control -- if THAT passes, the check is not
# actually reaching the compiler and the gate fails rather than reporting ok.
#
# THE ORDER IS ASKED OF A SECOND COMPILER when one is installed, because a single
# compiler cannot show a disagreement between two. With only clang present the order
# half reports what it skipped; it does not pass silently.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "bracket_depth_check: $MERE not found — run 'dune build'" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# --- part 1: depth -------------------------------------------------------------
# clang is the one with the 256 limit; gcc has none, so this half needs clang by name.
if command -v clang >/dev/null 2>&1; then
  N=300
  # A chain of string literals, a chain of conjuncts, and a cascade of arms: the three
  # shapes that nest one bracket per link. Nothing here has effects, so each is caught
  # by the length rule alone.
  awk -v n=$N 'BEGIN{printf "let _ = print ("; for(i=0;i<n;i++){printf "%s\"s%d\"", (i?" ++ ":""), i} printf ");\n0\n"}' \
    > "$TMP/chain.mere"
  awk -v n=$N 'BEGIN{printf "let f = fn (k: int) -> if "; for(i=0;i<n;i++){printf "%s(k > %d)", (i?" && ":""), i} printf " then 1 else 0;\nlet _ = print_int (f 9);\n0\n"}' \
    > "$TMP/conj.mere"
  awk -v n=$N 'BEGIN{printf "let f = fn (k: int) -> if k == 0 then 0"; for(i=1;i<n;i++){printf " else if k == %d then %d", i, i} printf " else -1;\nlet _ = print_int (f 9);\n0\n"}' \
    > "$TMP/casc.mere"
  # Every value is read by a lifted function, so it really becomes a C global.
  # Alternating with effects used to open two nested scopes per initializer.
  # Distinct names ensure this checks global initialization, not local shadowing.
  awk 'BEGIN{for(i=0;i<1000;i++){if(i==0) printf "let g0 = 0;\n"; else printf "let g%d = f%d () + 1;\n", i, i-1; printf "let f%d = fn () -> g%d;\nlet _ = f%d ();\n", i, i, i} printf "print_int (f999 ())\n"}' \
    > "$TMP/globals.mere"
  # A literal is a Cons spine, rather than a runtime range construction.
  awk 'BEGIN{printf "let xs = ["; for(i=0;i<1000;i++) printf "%s%d",(i?", ":""),i; printf "];\nlet _ = print_int (len xs);\nprint_int (list_fold xs 0 (fn i -> fn x -> if i == x then i + 1 else 0 - 1))\n"}' \
    > "$TMP/list.mere"

  for probe in chain conj casc globals list; do
    if ! "$MERE" -c "$TMP/$probe.mere" > "$TMP/$probe.c" 2>"$TMP/$probe.emit.err"; then
      echo "FAIL bracket_depth: mere -c refused the $probe probe"; sed -n '1,5p' "$TMP/$probe.emit.err"; fail=1; continue
    fi
    if clang -fsyntax-only -fbracket-depth=256 -w "$TMP/$probe.c" 2>"$TMP/$probe.cc.err"; then
      echo "bracket_depth: $probe fits at clang's default depth"
    else
      echo "FAIL bracket_depth: clang refused the $probe probe at -fbracket-depth=256"
      grep -i "bracket\|error" "$TMP/$probe.cc.err" | head -3
      fail=1
    fi
    # Armed-instrument control: the same file must be REFUSED when the limit is absurd.
    # Without this, a probe that failed to emit, or a clang that ignored the flag,
    # would read as a pass.
    if clang -fsyntax-only -fbracket-depth=4 -w "$TMP/$probe.c" 2>/dev/null; then
      echo "FAIL bracket_depth: $probe passed at -fbracket-depth=4 — the check is not reaching clang"
      fail=1
    fi
  done
  # Each initializer reads the preceding one: 999 depends on all 1,000 running.
  if clang -O2 -fbracket-depth=256 -w "$TMP/globals.c" -lm -o "$TMP/globals" \
       2>"$TMP/globals.link.err" \
       && "$TMP/globals" > "$TMP/globals.out" \
       && [ "$(cat "$TMP/globals.out")" = 999 ]; then
    echo "bracket_depth: all 1000 global initializers run"
  else
    echo "FAIL bracket_depth: the global initialization probe did not return 999"
    sed -n '1,3p' "$TMP/globals.link.err"
    fail=1
  fi
  if clang -O2 -fbracket-depth=256 -w "$TMP/list.c" -lm -o "$TMP/list" \
       2>"$TMP/list.link.err" \
       && "$TMP/list" > "$TMP/list.out" \
       && [ "$(cat "$TMP/list.out")" = "$(printf '1000\n1000')" ]; then
    echo "bracket_depth: all 1000 list elements retain their order and values"
  else
    echo "FAIL bracket_depth: the list literal did not retain its length and element order"
    sed -n '1,3p' "$TMP/list.link.err"
    fail=1
  fi
else
  echo "bracket_depth: SKIP depth half (no clang; gcc has no bracket limit to ask about)"
fi

# --- part 2: order -------------------------------------------------------------
# One compiler cannot disagree with itself. Build the same emitted C with every C
# compiler on this machine and require all of them to match the interpreter.
for P in "$ROOT/test/parity/eval_order_operands.mere" \
         "$ROOT/test/parity/top_global_initializers.mere" \
         "$ROOT/test/parity/list_construction_order.mere"; do
if [ -f "$P" ]; then
  "$MERE" "$P" > "$TMP/interp.out" 2>&1 || { echo "FAIL bracket_depth: interp refused the order probe"; fail=1; }
  "$MERE" -c "$P" > "$TMP/order.c" 2>"$TMP/order.err" || { echo "FAIL bracket_depth: mere -c on the order probe"; sed -n '1,5p' "$TMP/order.err"; fail=1; }
  found=0
  seen=""
  for cc in clang gcc cc; do
    command -v "$cc" >/dev/null 2>&1 || continue
    # Identity, not path: on macOS `gcc` and `cc` are both Apple clang, and three names
    # for one compiler cannot disagree with each other. Ask each what it is.
    id="$("$cc" --version 2>/dev/null | head -1 | tr -d ' \t')"
    case "|${seen:-}|" in *"|$id|"*) continue;; esac
    seen="${seen:-}|$id"
    found=$((found + 1))
    if ! "$cc" -O0 -w "$TMP/order.c" -lm -o "$TMP/order.$cc" 2>"$TMP/order.$cc.err"; then
      echo "FAIL bracket_depth: $cc could not build the order probe"; sed -n '1,3p' "$TMP/order.$cc.err"; fail=1; continue
    fi
    "$TMP/order.$cc" > "$TMP/order.$cc.out" 2>&1
    if cmp -s "$TMP/interp.out" "$TMP/order.$cc.out"; then
      echo "bracket_depth: $cc agrees with the interpreter on ${P##*/}"
    else
      echo "FAIL bracket_depth: $cc disagrees with the interpreter on operand order"
      diff "$TMP/interp.out" "$TMP/order.$cc.out" | head -8
      fail=1
    fi
  done
  [ "$found" -ge 2 ] || echo "bracket_depth: only $found distinct C compiler here (${seen:-none}) — the order half needs two to show a disagreement; the CI runner has clang and gcc both"
else
  echo "FAIL bracket_depth: $P is missing"; fail=1
fi
done

[ "$fail" -eq 0 ] || exit 1
echo "bracket_depth_check: ok"
