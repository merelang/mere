#!/bin/sh
# scripts/rv_listing_check.sh — `mere -rvs` / `-rv64s` (the listing) and
# `-rvg` / `-rv64g` (the debug map) must describe THE binary `-rv` / `-rv64`
# emits, word for word.
#
# They did not until v0.1.610. Only the binary path settled the undecided
# container regions (Q-127) before generating code, so the listing and the map
# were made from a different program: on 15 of the parity programs the listing's
# words disagreed with the binary's, and on mere-ruby the debug map put every
# function at the wrong address -- a sampling profile built on it said startup
# spent 26% in `do_class_alias` and 7% in lgamma's helper; the truth was the
# Map. And in a wide layout (code past 512 KB, jumps as auipc+jalr) the listing
# still encoded each jump as a J-type first and refused anything over 1 MB.
#
# What this checks, for every parity program at both widths: each listing line
# that shows an encoded word has that word at that address in the binary, and
# each function symbol of the debug map is a label of the listing at the same
# address. Plus one generated program big enough to take the wide layout.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "rv_listing: $MERE not found — run 'dune build'" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0; checked=0; words=0

# word-for-word: the listing's "  <hex addr>:  <8 hex>  ..." lines against the
# binary's 32-bit little-endian words (od prints them in host order, which is
# little-endian on every machine this runs on)
check_one() {  # $1 = flag (-rv / -rv64), $2 = program
  flag=$1; prog=$2
  b="$TMP/b.bin"; l="$TMP/l.s"; g="$TMP/g.map"
  "$MERE" $1 "$2" > "$b" 2>/dev/null || return 0      # a program the backend refuses is not this gate's
  "$MERE" ${1}s "$2" > "$l" 2>"$TMP/err" || { echo "FAIL rv_listing: ${1}s refused $(basename "$2"), which ${1} built"; head -2 "$TMP/err"; rc=1; return 0; }
  "$MERE" ${1}g "$2" > "$g" 2>"$TMP/err" || { echo "FAIL rv_listing: ${1}g refused $(basename "$2"), which ${1} built"; rc=1; return 0; }
  od -A d -t x4 -v "$b" | awk 'NF > 1 { a = $1; for (i = 2; i <= NF; i++) print (a + 4 * (i - 2)), $i }' > "$TMP/words"
  out=$(awk '
    FNR == NR { w[$1] = $2; next }
    /^ +[0-9a-f]+: +[0-9a-f]{8} / {
      a = $1; sub(":", "", a); addr = 0
      for (i = 1; i <= length(a); i++) addr = addr * 16 + index("0123456789abcdef", substr(a, i, 1)) - 1
      n++; if (w[addr] != $2) { bad++; if (bad <= 3) print "  at " a ": listing " $2 ", binary " w[addr] }
    }
    END { print "N " n + 0 " " bad + 0 }' "$TMP/words" "$l")
  nw=$(printf '%s\n' "$out" | tail -1 | awk '{print $2}')
  nbad=$(printf '%s\n' "$out" | tail -1 | awk '{print $3}')
  words=$((words + nw)); checked=$((checked + 1))
  if [ "$nbad" != 0 ]; then
    echo "FAIL rv_listing: $(basename "$prog") at $flag: $nbad of $nw listed words are not the binary's"
    printf '%s\n' "$out" | grep '^  at ' ; rc=1
  fi
  # every function symbol of the map is a label of the listing at that address
  awk '$1 == "S" && $3 !~ /^\./ { print $3, $2 }' "$g" | sort > "$TMP/gsyms"
  awk '/^[A-Za-z_][A-Za-z0-9_.$]*:$/ { name = substr($0, 1, length($0) - 1); next }
       name != "" && /^ +[0-9a-f]+:/ { a = $1; sub(":", "", a); addr = 0
         for (i = 1; i <= length(a); i++) addr = addr * 16 + index("0123456789abcdef", substr(a, i, 1)) - 1
         print name, addr; name = "" }' "$l" | sort > "$TMP/lsyms"
  miss=$(comm -23 "$TMP/gsyms" "$TMP/lsyms" | wc -l | tr -d ' ')
  if [ "$miss" != 0 ]; then
    echo "FAIL rv_listing: $(basename "$prog") at $flag: $miss debug-map symbols are not listing labels at that address"
    comm -23 "$TMP/gsyms" "$TMP/lsyms" | head -3; rc=1
  fi
}

for f in "$ROOT"/test/parity/*.mere; do
  check_one -rv "$f"; check_one -rv64 "$f"
done

# wide layout: each function calls the next one (on a branch never taken), so
# reachability keeps all 3000 of them -- over 1 MB of code, every jump wide and
# the far ones past J-type's reach
W="$TMP/wide.mere"
awk 'BEGIN {
  n = 3000
  for (i = 0; i < n; i++) {
    printf "let rec f%d = fn (x: int) -> let a = x * %d + 1 in let b = a / 3 + x in let c = (if b > %d then b - a else a + b) in\n", i, i + 3, i
    printf "  let d = c * c - a in let e = (if d %% 2 == 0 then d / 2 else d * 3 + 1) in\n"
    if (i + 1 < n) printf "  e + a + b + c + (if x < 0 - 1000000000 then f%d (x + 1) else 0);\n", i + 1
    else printf "  e + a + b + c;\n"
  }
  printf "print (str_of_int (f0 7))\n"
}' > "$W"
check_one -rv64 "$W"
wide=$(grep -c 'auipc+jalr' "$TMP/l.s" || true)
if [ "$wide" = 0 ]; then echo "FAIL rv_listing: the generated program did not take the wide layout (the case this exists for)"; rc=1; fi

[ "$rc" = 0 ] && echo "ok rv_listing: $checked listings ($words encoded words, incl. a wide one with $wide auipc+jalr jumps) are the binary word for word, and every debug-map symbol is a listing label"
exit $rc
