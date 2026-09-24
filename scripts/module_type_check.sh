#!/bin/sh
# scripts/module_type_check.sh — a type declared inside `module M { }` can be
# written down, and two different types cannot share a name.
#
# Q-125. A record declared in a module could not be named in an annotation --
# not from outside, and NOT FROM INSIDE THE MODULE THAT DECLARED IT:
#
#     module M { type t = { a: int }; let get = fn (v: t) -> v.a; }
#
# did not compile. Variants never had this, because their rename lands on the
# CONSTRUCTOR (`M.A` still builds a `v`) while a record's landed on the TYPE
# NAME, so a literal was an `M.t` and every annotation resolved to `t`.
#
# ⚠ WHY THE TWINS ARE MEASURED SIDE BY SIDE. The bug was not "records are
# broken", it was "records and variants disagree", and nothing asked them the
# same question. Each case below is asked of both.
#
# ⚠ AND THE CLASH CHECK COMES WITH IT. Making `M.t` and `t` one type means two
# different records sharing a name would silently BE the same type. Variants
# already refused that; records accepted it in silence until v0.1.525, so the
# refusal is checked here too — a fix that needs a guard is not finished until
# the guard is there.
#
# Usage:
#   sh scripts/module_type_check.sh            # check
#   sh scripts/module_type_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "module_type: $MERE not built" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MODE="${1:-}"
fail=0

accepts() { # $1=label $2=program $3=expected output
  printf '%s\n' "$2" > "$T/p.mere"
  got=$("$MERE" "$T/p.mere" 2>&1 | tail -1)
  if [ "$got" = "$3" ]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s\n' "$1: got \"$got\", wanted $3"
    fail=1
  fi
}
refuses() { # $1=label $2=program $3=phrase the refusal must contain
  printf '%s\n' "$2" > "$T/p.mere"
  out=$("$MERE" "$T/p.mere" 2>&1)
  if "$MERE" "$T/p.mere" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "$1: accepted, and it must not be"
    fail=1
  elif printf '%s' "$out" | grep -q "$3"; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s\n' "$1: refused for another reason: $(printf '%s' "$out" | head -1 | cut -c1-70)"
    fail=1
  fi
}

REC='module M { type t = { a: int }; let mk = fn (x: int) -> t { a = x }; let get = fn (v: t) -> v.a; }'
VAR='module M { type v = A of int | B; let mk = fn (x: int) -> A x; let get = fn (u: v) -> match u with | A n -> n | B -> 0; }'

# --- the four spellings, for both kinds ------------------------------------
accepts "record: the declaring module can annotate with its own type" \
  "$REC
print_int (M.get (M.mk 7))" 7
accepts "variant: the same" \
  "$VAR
print_int (M.get (M.mk 7))" 7

accepts "record: a qualified annotation names it from outside" \
  "$REC
let p = (M.mk 7 : M.t);
print_int p.a" 7
accepts "variant: the same" \
  "$VAR
let u = (M.mk 7 : M.v);
print_int (M.get u)" 7

accepts "record: a bare annotation names it from outside" \
  "$REC
let p = (M.mk 7 : t);
print_int p.a" 7
accepts "variant: the same" \
  "$VAR
let u = (M.mk 7 : v);
print_int (M.get u)" 7

accepts "record: no annotation at all still reads a field" \
  "$REC
print_int (M.mk 7).a" 7
accepts "variant: no annotation at all still matches" \
  "$VAR
print_int (M.get (M.mk 7))" 7

# --- two different types may not share a name ------------------------------
refuses "record: two modules, same name, different fields" \
  'module A { type t = { a: int }; let mk = fn (x: int) -> t { a = x }; }
module B { type t = { b: str }; let take = fn (u: t) -> str_len u.b; }
print_int (B.take (A.mk 7))' 'different fields'
refuses "variant: two modules, same name, different constructors" \
  'module A { type v = P of int; let mk = fn (x: int) -> P x; }
module B { type v = Q of str; let take = fn (u: v) -> match u with | Q s -> str_len s; }
print_int (B.take (A.mk 7))' 'different constructors'

refuses "record: restated at top level with different fields" \
  'type t = { a: int };
type t = { b: str };
print_int 0' 'different fields'
refuses "variant: restated at top level with different constructors" \
  'type v = P of int;
type v = Q of str;
print_int 0' 'different constructors'

# ⚠ Restating IDENTICALLY is not a clash -- twelve files in this repo restate
# `'"'"'a list`. A guard that refused that would be worse than the hole.
accepts "record: restating the same fields is not a clash" \
  'type t = { a: int };
type t = { a: int };
print_int 0' 0

# --- it has to RUN, on every backend that can build it ---------------------
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
cat > "$T/run.mere" <<'EOF'
module M {
  type t = { a: int, b: str };
  let mk = fn (x: int) -> t { a = x, b = "v" };
  let get = fn (v: t) -> v.a;
}
let p = (M.mk 20 : M.t);
print_int (M.get p + 22)
EOF
if command -v "$CC" >/dev/null 2>&1; then
  for pair in "-c c C" "-ll ll LLVM"; do
    set -- $pair
    if "$MERE" "$1" "$T/run.mere" > "$T/o.$2" 2>/dev/null \
       && "$CC" -w -O0 -o "$T/b.$2" "$T/o.$2" -lm 2>/dev/null; then
      got=$("$T/b.$2" 2>&1 | tail -1)
      if [ "$got" = "42" ]; then printf '  ok    %s\n' "$3: builds and prints 42"
      else printf '  FAIL  %s\n' "$3 printed \"$got\""; fail=1; fi
    else
      printf '  note  %s\n' "$3 could not be built here"
    fi
  done
fi

if [ "$MODE" = "--poison" ]; then
  pfail=0
  # POISON 1: ⚠ the clash check is what makes the canonicalisation safe, so
  # prove the fixture can tell a clash from a restatement -- if `{ a }` and
  # `{ b }` compared equal, the refusal above would be vacuous.
  printf 'type t = { a: int };\ntype t = { b: str };\nprint_int 0\n' > "$T/p1.mere"
  printf 'type t = { a: int };\ntype t = { a: int };\nprint_int 0\n' > "$T/p2.mere"
  if "$MERE" "$T/p1.mere" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "POISON 1: a real clash was accepted"; pfail=1
  elif ! "$MERE" "$T/p2.mere" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "POISON 1: an identical restatement was refused — the check is too eager"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 1: a clash is refused and a restatement is not, so the check reads the fields"
  fi
  # POISON 2: the accepting direction must be able to fail. A type nobody
  # declared has to be refused, or `accepts` proves nothing.
  printf 'module M { type t = { a: int }; }\nlet p = (0 : M.nosuch);\nprint_int 0\n' > "$T/p3.mere"
  if "$MERE" "$T/p3.mere" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "POISON 2: an undeclared type was accepted in an annotation"; pfail=1
  else
    printf '  ok    %s\n' "POISON 2 (a type nobody declared): refused"
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "module_type --poison: ok (the gate can go red)"
  else
    echo "module_type --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "module_type: ok"; else echo "module_type: FAILED"; fi
exit "$fail"
