#!/bin/sh
# scripts/doc_coverage_check.sh — every builtin's name appears in a hand-written doc.
#
# `mere --dump-builtins` is the compiler's own list of what a program can call.
# scripts/host_matrix.sh already asks WHICH BACKEND has each one; nothing asked
# whether the documentation has heard of it. Measured when this was written: 25
# of 221 appeared in no hand-written doc at all, including every `bytes_*` name
# -- a first-class type with a whole arc behind it -- and `vec_reverse`, which
# did not appear in a single file under docs/, not even the changelog.
#
# WHY THIS GATE EXISTS AT ALL. A claim that a capability is missing is worth
# less than the search that produced it, and the search people actually run is
# "grep the docs". `try_or` was documented and got asserted as absent anyway
# (v0.1.361); these 25 would not have been found by anyone doing it right.
#
# WHAT IT DOES NOT CHECK, said plainly because a coverage number invites the
# other reading: this asks whether the NAME IS SPELLED SOMEWHERE, not whether it
# is explained, not whether the explanation is correct, and not whether it is
# reachable from a table of contents. It is the weakest useful question, and its
# value is that the answer cannot be argued with.
#
# That weakness bit on the first poison run. The paragraph introducing the new
# roster in stdlib-reference.md named two of the builtins it was there to cover,
# as examples of what had been missing -- so deleting a row left the name in the
# prose ABOUT the row and the gate stayed green. The sentence names no builtins
# now. A gate this shallow is satisfied by a mention of any kind, including a
# mention that the thing is undocumented.
#
# SCOPE. Hand-written docs only. docs/changelog.md is history -- a name that
# appears there and nowhere else has been announced and never documented, which
# is the case this gate is looking for. docs/host-matrix.md is generated from
# the same builtin list this reads, so counting it would make the gate pass by
# citing itself.
#
# ALLOWLIST. docs/UNDOCUMENTED_ALLOW holds `<name> <reason>` lines for builtins
# deliberately left out. An entry whose builtin has since been documented is an
# ERROR, not a pass: the list cannot rot into a to-do list nobody rereads.
#
# Usage: scripts/doc_coverage_check.sh
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOW="$ROOT/docs/UNDOCUMENTED_ALLOW"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$MERE" ] || { echo "doc_coverage: $MERE not found — run dune build first" >&2; exit 1; }

DOCS=""
for f in "$ROOT"/docs/*.md; do
  case "$f" in
    */changelog.md|*/host-matrix.md) ;;
    *) DOCS="$DOCS $f" ;;
  esac
done
[ -n "$DOCS" ] || { echo "doc_coverage: no docs to search" >&2; exit 1; }

"$MERE" --dump-builtins 2>/dev/null | awk '{print $1}' | sort -u > "$TMP/builtins"
total=$(wc -l < "$TMP/builtins" | tr -d ' ')
[ "$total" -gt 0 ] || { echo "doc_coverage: --dump-builtins produced nothing" >&2; exit 1; }

: > "$TMP/missing"
while read -r b; do
  # shellcheck disable=SC2086
  grep -qE "(^|[^A-Za-z0-9_])$b([^A-Za-z0-9_]|$)" $DOCS 2>/dev/null || printf '%s\n' "$b" >> "$TMP/missing"
done < "$TMP/builtins"

allowed=0
: > "$TMP/allow_names"
if [ -f "$ALLOW" ]; then
  grep -v '^[[:space:]]*#' "$ALLOW" | grep -v '^[[:space:]]*$' | awk '{print $1}' > "$TMP/allow_names"
  allowed=$(wc -l < "$TMP/allow_names" | tr -d ' ')
fi

fail=0

# Undocumented and not excused.
: > "$TMP/unexcused"
while read -r b; do
  grep -qx "$b" "$TMP/allow_names" 2>/dev/null || printf '%s\n' "$b" >> "$TMP/unexcused"
done < "$TMP/missing"
n_unexcused=$(wc -l < "$TMP/unexcused" | tr -d ' ')

if [ "$n_unexcused" != 0 ]; then
  echo "doc_coverage: $n_unexcused builtin(s) appear in no hand-written doc and are not in UNDOCUMENTED_ALLOW:"
  sed 's/^/    /' "$TMP/unexcused"
  fail=1
fi

# Excused but documented: the entry has stopped being true.
if [ -s "$TMP/allow_names" ]; then
  while read -r b; do
    if ! grep -qx "$b" "$TMP/missing" 2>/dev/null; then
      echo "doc_coverage: UNDOCUMENTED_ALLOW lists \`$b\`, which IS documented now — remove the entry"
      fail=1
    fi
  done < "$TMP/allow_names"
fi

n_missing=$(wc -l < "$TMP/missing" | tr -d ' ')
echo "doc_coverage: $total builtins, $((total - n_missing)) named in a hand-written doc, $n_missing not ($allowed excused)"

[ "$fail" = 0 ] || exit 1
echo "doc_coverage: ok"
