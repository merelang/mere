#!/bin/sh
# scripts/contrib_ctest.sh — contrib's self-tests, on the backend that ships.
#
# EVERY LIBRARY IN contrib/ HAS SELF-TESTS AND THEY RAN UNDER THE INTERPRETER.
# That is a whole class of bug this project could not see: `contrib/toml` had
# never produced C that compiles, for any version of the compiler there has
# ever been, because `let init = ("", Nil)` was emitted with the empty list
# defaulted to `int` and handed to a fold that wanted a list of pairs. The
# interpreter has no such type to get wrong, so nothing said a word — until an
# editor tried to read a config file (mere v0.1.478).
#
# So this runs each library the way `scripts/ctest.sh` runs the test corpus:
# emit C, compile it, run it, and diff its output against the interpreter's.
# It is the same script, pointed at a different list.
#
# WHY A LIST AND NOT A GLOB. A glob that silently skips what will not compile
# reports "all green" when the set it checked shrank to nothing. The list is
# explicit, its length is asserted, and a file that stops compiling fails
# instead of leaving.
#
# Usage:  sh scripts/contrib_ctest.sh
#         MERE=/path/to/mere sh scripts/contrib_ctest.sh
#
# Takes about four minutes: it compiles and runs 87 programs. It is not in
# `dune runtest` for that reason; it belongs with the other differential gates.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}
[ -x "$MERE" ] || { echo "contrib_ctest: $MERE not found — run dune build first" >&2; exit 1; }
command -v clang >/dev/null 2>&1 || command -v cc >/dev/null 2>&1 || {
  echo "contrib_ctest: no C compiler — skipping" >&2; exit 0; }

LIST="$ROOT/test/contrib_ctests.txt"
[ -f "$LIST" ] || { echo "contrib_ctest: $LIST is missing" >&2; exit 1; }

# --- the subjects ----------------------------------------------------------
# Comments and blanks out; every other line is a path that must exist.
FILES=$(grep -vE '^\s*(#|$)' "$LIST")
COUNT=$(printf '%s\n' "$FILES" | grep -c .)

# The count is asserted so that a list which quietly loses entries -- a library
# renamed, a line deleted in a merge -- fails rather than passing over fewer
# subjects. Raise it deliberately when contrib grows.
EXPECT=${CONTRIB_CTEST_EXPECT:-87}
if [ "$COUNT" -ne "$EXPECT" ]; then
  echo "FAIL contrib_ctest: the list holds $COUNT entries and $EXPECT were expected."
  echo "  A shorter list is a smaller gate, and a gate that shrinks passes for the"
  echo "  wrong reason. Update EXPECT in this script together with the list."
  exit 1
fi

missing=0
for f in $FILES; do
  [ -f "$f" ] || { echo "FAIL contrib_ctest: $f is in the list and not on disk"; missing=1; }
done
[ "$missing" = "0" ] || exit 1

# --- the known failures, pinned by PATH ------------------------------------
# Named by `<dir>/<stem>`, which is what ctest.sh reports. Not by basename:
# five of these basenames appear in two libraries each, and a pin on `gen`
# would cover `contrib/gen/gen.mere` and `contrib/proto/gen.mere` at once.
#
# Each line is a class, not an excuse:
#
#   wasm    the Wasm backend refuses to emit these. A separate, tracked gap;
#           the C backend builds and runs them, which is what this gate is for.
#   interp  the INTERPRETER cannot run it — contrib/site/build.mere recurses
#           deeper than the interpreter's stack allows and the native binary
#           completes. There is no output to diff against, and the native side
#           is the one that works.
KNOWN_WASM="font/font html/entities html/tokenizer proto/gen raster/canvas raster/path stream/stream"
KNOWN_INTERP="site/build"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sh "$ROOT/scripts/ctest.sh" $FILES > "$TMP/out" 2>&1 || true

fail=0
pass_n=$(grep -c '^PASS ' "$TMP/out" || true)

# A failure is allowed only if it is pinned AND fails for the pinned reason.
# "Some failure with that name" would let a miscompile hide behind a known
# Wasm gap.
while IFS= read -r line; do
  case "$line" in
    FAIL\ *) ;;
    *) continue ;;
  esac
  who=$(printf '%s' "$line" | sed 's/^FAIL \([^:]*\):.*/\1/')
  why=$(printf '%s' "$line" | sed 's/^FAIL [^:]*: *//')
  expected=""
  for k in $KNOWN_WASM; do [ "$k" = "$who" ] && expected="Wasm emission failed"; done
  for k in $KNOWN_INTERP; do [ "$k" = "$who" ] && expected="native/interp mismatch"; done
  if [ -z "$expected" ]; then
    echo "FAIL contrib_ctest: $who — $why"
    echo "  A contrib library stopped building or stopped agreeing with the"
    echo "  interpreter. This is the case that was invisible until v0.1.478."
    fail=1
  elif [ "$why" != "$expected" ]; then
    echo "FAIL contrib_ctest: $who fails for a NEW reason."
    echo "  pinned:  $expected"
    echo "  now:     $why"
    fail=1
  fi
done < "$TMP/out"

# And the other direction: a pinned failure that starts passing has to be
# unpinned, or the pin rots into a claim nobody checks.
for k in $KNOWN_WASM $KNOWN_INTERP; do
  if grep -q "^PASS $k " "$TMP/out"; then
    echo "FAIL contrib_ctest: $k is pinned as a known failure and now PASSES."
    echo "  Remove it from the pin. A gate that cannot notice a fix stops being"
    echo "  a measurement of anything."
    fail=1
  fi
done

if [ "$fail" = "0" ]; then
  known=$(printf '%s %s' "$KNOWN_WASM" "$KNOWN_INTERP" | wc -w | tr -d ' ')
  echo "PASS contrib_ctest: $pass_n of $COUNT contrib libraries compile and agree with the interpreter; $known pinned (7 Wasm emission, 1 the interpreter's own stack)"
  exit 0
fi
echo "contrib_ctest: see $TMP/out" >&2
sed -n '1,200p' "$TMP/out" >&2
exit 1
