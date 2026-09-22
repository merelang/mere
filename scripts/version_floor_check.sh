#!/bin/sh
# scripts/version_floor_check.sh — the feature/version table, checked rather
# than declared.
#
# `lib/feature.ml` says which version each feature first compiled in. That is a
# claim about history, and a claim in a table is the kind of thing that is right
# on the day it is written and never looked at again. Three questions here:
#
#   1. EVERY ROW HAS A WITNESS. The compiler prints its own rows (`mere
#      --features`); each one must have a file in test/version_floor/ that uses
#      that feature and nothing else newer. A row with no file is a row nobody
#      tests, and the count is compared so that ADDING a row without a file
#      turns this red.
#   2. EVERY ROW IS DERIVED, NOT REMEMBERED. Each row's version is re-derived
#      from docs/changelog.md the way it was originally read off it: find the
#      oldest mention of the feature's probe word, take the version heading of
#      the section it is in. A row that disagrees with the record it came from
#      fails here.
#   3. THE FLOOR IS ENFORCED. A package declaring a version above this compiler
#      must be refused, by both `mere check` and `mere install`, in a message
#      that names both versions — the whole point of the mechanism is that the
#      failure stops being a parse error in someone else's file.
#
# Usage:
#   sh scripts/version_floor_check.sh            # check
#   sh scripts/version_floor_check.sh --poison   # check that it can go red
#
# THE POISONS are two:
#   1. a row whose version is wrong (rewrite one snippet's expectation) must
#      fail question 1/2's comparison;
#   2. a declared floor BELOW this compiler must NOT be refused — a gate that
#      cannot tell the two directions apart would pass with `<` written for `>`.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
CASES="$ROOT/test/version_floor"
CHANGELOG="$ROOT/docs/changelog.md"

[ -x "$MERE" ] || { echo "version_floor: $MERE not built" >&2; exit 2; }
[ -f "$CHANGELOG" ] || { echo "version_floor: $CHANGELOG missing" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/version_floor.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail=0

# The version of the changelog section that first (oldest) mentions a word.
# The file is newest-first, so the last mention is the earliest one, and the
# heading above it is the section it lives in.
derive() {  # probe -> 0.1.NNN, or empty
  _ln=$(grep -n -- "$1" "$CHANGELOG" | tail -1 | cut -d: -f1)
  [ -n "$_ln" ] || return 0
  head -n "$_ln" "$CHANGELOG" | grep -oE '^## v0\.1\.[0-9]+' | tail -1 | sed 's/^## v//'
}

# What `mere fix` computes for one file, as a bare version.
computed() {  # file -> ">= x.y.z" floor written into a scratch manifest
  rm -rf "$tmp/pkg"; mkdir -p "$tmp/pkg"
  printf '[package]\nname = "floorprobe"\nversion = "0.1.0"\n' > "$tmp/pkg/mere.toml"
  cp "$1" "$tmp/pkg/app.mere"
  "$MERE" fix "$tmp/pkg/app.mere" >/dev/null 2>&1 || true
  sed -n 's/^mere = ">= \(.*\)"$/\1/p' "$tmp/pkg/mere.toml"
}

rows=$("$MERE" --features)
n_rows=$(printf '%s\n' "$rows" | grep -c .)
n_cases=$(ls "$CASES"/*.mere 2>/dev/null | wc -l | tr -d ' ')

if [ "$n_rows" = "$n_cases" ]; then
  printf '  ok    %s\n' "$n_rows rows in the table, $n_cases files to witness them"
else
  printf '  FAIL  %s\n' "$n_rows rows in the table but $n_cases files in test/version_floor/"
  fail=1
fi

printf '%s\n' "$rows" | while IFS='	' read -r name since probe; do
  [ -n "${probe:-}" ] || continue
  got=$(derive "$probe")
  if [ "$got" = "$since" ]; then
    printf '  ok    %s: %s, re-derived from the changelog\n' "$probe" "$since"
  else
    printf '  FAIL  %s: the table says %s, the changelog says %s\n' "$probe" "$since" "${got:-<not mentioned>}"
    echo fail >> "$tmp/failed"
  fi
  case_file="$CASES/$probe.mere"
  if [ ! -f "$case_file" ]; then
    printf '  FAIL  %s: no witness file at test/version_floor/%s.mere\n' "$probe" "$probe"
    echo fail >> "$tmp/failed"
  else
    c=$(computed "$case_file")
    if [ "$c" = "$since" ]; then
      printf '  ok    %s: `mere fix` computes %s from its own witness\n' "$probe" "$c"
    else
      printf '  FAIL  %s: `mere fix` computed %s, the table says %s\n' "$probe" "${c:-<nothing>}" "$since"
      echo fail >> "$tmp/failed"
    fi
  fi
done
[ -f "$tmp/failed" ] && fail=1

# --- enforcement, in both directions ---------------------------------------
enforce() {  # declared-floor -> refused / accepted
  rm -rf "$tmp/enf"; mkdir -p "$tmp/enf"
  printf '[package]\nname = "enf"\nversion = "0.1.0"\nmere = ">= %s"\n' "$1" > "$tmp/enf/mere.toml"
  printf 'print "ok"\n' > "$tmp/enf/app.mere"
  if "$MERE" check "$tmp/enf/app.mere" >/dev/null 2>&1; then echo accepted; else echo refused; fi
}

if [ "$(enforce 99.0.0)" = "refused" ]; then
  printf '  ok    %s\n' "a floor above this compiler is refused"
else
  printf '  FAIL  %s\n' "a floor above this compiler was accepted"
  fail=1
fi
if [ "$(enforce 0.0.1)" = "accepted" ]; then
  printf '  ok    %s\n' "a floor below this compiler is accepted"
else
  printf '  FAIL  %s\n' "a floor below this compiler was refused"
  fail=1
fi
# The message has to name both versions; "refused" on its own is not an answer.
msg=$("$MERE" check "$tmp/enf/app.mere" 2>&1 || true)
rm -rf "$tmp/enf"; mkdir -p "$tmp/enf"
printf '[package]\nname = "enf"\nversion = "0.1.0"\nmere = ">= 99.0.0"\n' > "$tmp/enf/mere.toml"
printf 'print "ok"\n' > "$tmp/enf/app.mere"
msg=$("$MERE" check "$tmp/enf/app.mere" 2>&1 || true)
if printf '%s' "$msg" | grep -q '99\.0\.0' && printf '%s' "$msg" | grep -q "$("$MERE" -v 2>/dev/null | tr -d 'merv ')"; then
  printf '  ok    %s\n' "the refusal names both the required and the running version"
else
  printf '  FAIL  %s\n' "the refusal does not name both versions: $msg"
  fail=1
fi

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  # POISON 1: a witness that does not use its feature must stop computing the
  # row's version.
  printf 'print "ok"\n' > "$tmp/empty.mere"
  if [ -z "$(computed "$tmp/empty.mere")" ]; then
    printf '  ok    %s\n' "POISON 1 (a file using no feature): no floor computed"
  else
    printf '  FAIL  %s\n' "POISON 1: a floor was computed for a file that uses nothing"
    pfail=1
  fi
  # POISON 2: a probe word that the changelog never mentions must derive nothing.
  if [ -z "$(derive 'zzz_not_a_feature_zzz')" ]; then
    printf '  ok    %s\n' "POISON 2 (a word not in the changelog): derives nothing"
  else
    printf '  FAIL  %s\n' "POISON 2: derived a version for a word that is not there"
    pfail=1
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "version_floor --poison: ok (the gate can go red)"
  else
    echo "version_floor --poison: FAILED"
    pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "version_floor: ok"; else echo "version_floor: FAILED"; fi
exit "$fail"
