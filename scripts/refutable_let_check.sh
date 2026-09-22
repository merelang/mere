#!/bin/sh
# scripts/refutable_let_check.sh — a `let` that can fail is refused, and
# nothing else is.
#
# `let Some n = e;` is a match with one arm. Until v0.1.505 the two constructs
# gave different answers to the same question: the `match` was refused at
# compile time and the `let` compiled and failed at run time. This gate holds
# the three cases that keep that fix from becoming a nuisance:
#
#   1. a refutable pattern is REFUSED, and the message NAMES the value that
#      does not match (a refusal that does not say what is missing sends the
#      reader looking for a typo);
#   2. an irrefutable pattern is accepted — tuples, records, plain names, and
#      a constructor pattern on a type that has only ONE constructor, which is
#      total and must stay free;
#   3. `if let` is accepted. It is the construct for a pattern that may not
#      match, and the parser turns it into a two-armed match — but that is
#      true because of how it is written today, so it is pinned here.
#
# Usage:
#   sh scripts/refutable_let_check.sh            # check
#   sh scripts/refutable_let_check.sh --poison   # check that it can go red
#
# THE POISONS are two, one per direction:
#   1. the one-constructor `let` must stay accepted — a gate that passed with
#      it refused would accept a check that rejects every constructor pattern;
#   2. the refutable `let` must stay refused when the type gains a second
#      constructor, which is the edit that creates this bug in real code.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "refutable_let: $MERE not built" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/refutable_let.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail=0
accepts() { "$MERE" check "$1" >/dev/null 2>&1; }
message() { "$MERE" check "$1" 2>&1 | head -1; }

cat > "$tmp/refutable.mere" <<'EOF'
type o = None | Some of int;
let Some n = None;
print_int n
EOF
if accepts "$tmp/refutable.mere"; then
  printf '  FAIL  %s\n' "a refutable let was accepted"
  fail=1
else
  msg=$(message "$tmp/refutable.mere")
  if printf '%s' "$msg" | grep -q 'missing None'; then
    printf '  ok    %s\n' "a refutable let is refused, naming the missing value"
  else
    printf '  FAIL  %s (%s)\n' "the refusal does not name what is missing" "$msg"
    fail=1
  fi
fi

cat > "$tmp/irrefutable.mere" <<'EOF'
type pt = Pt of int;
type Box = { w: int, h: int };
let (a, b) = (1, 2);
let Pt n = Pt 7;
let Box { w = ww, h = hh } = Box { w = 3, h = 4 };
print_int (a + b + n + ww + hh)
EOF
if accepts "$tmp/irrefutable.mere"; then
  printf '  ok    %s\n' "tuples, records and a one-constructor pattern are accepted"
else
  printf '  FAIL  %s (%s)\n' "an irrefutable let was refused" "$(message "$tmp/irrefutable.mere")"
  fail=1
fi

cat > "$tmp/iflet.mere" <<'EOF'
type o = None | Some of int;
let pick = fn (x: o) -> if let Some n = x then n else 0;
print_int (pick (Some 5) + pick None)
EOF
if accepts "$tmp/iflet.mere"; then
  printf '  ok    %s\n' 'if let is untouched (it is a two-armed match)' 
else
  printf '  FAIL  %s (%s)\n' 'if let was refused' "$(message "$tmp/iflet.mere")"
  fail=1
fi

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  # POISON 1: one constructor stays accepted.
  cat > "$tmp/p1.mere" <<'EOF'
type pt = Pt of int;
let Pt n = Pt 7;
print_int n
EOF
  if accepts "$tmp/p1.mere"; then
    printf '  ok    %s\n' "POISON 1 (one constructor): still accepted"
  else
    printf '  FAIL  %s\n' "POISON 1: the check refuses every constructor pattern"
    pfail=1
  fi
  # POISON 2: the same file with a second constructor must now be refused.
  cat > "$tmp/p2.mere" <<'EOF'
type pt = Pt of int | Origin;
let Pt n = Pt 7;
print_int n
EOF
  if accepts "$tmp/p2.mere"; then
    printf '  FAIL  %s\n' "POISON 2: a second constructor did not make it refutable"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 2 (a second constructor): now refused"
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "refutable_let --poison: ok (both directions hold)"
  else
    echo "refutable_let --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "refutable_let: ok"; else echo "refutable_let: FAILED"; fi
exit "$fail"
