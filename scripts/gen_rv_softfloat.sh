#!/bin/sh
# scripts/gen_rv_softfloat.sh — generate lib/rv_softfloat.ml from contrib/softfloat.
#
# The RV32I backend has no float, so `+` on two floats is computed in integers by
# this library. The prelude cannot `import` it: an installed compiler has no
# contrib/ on disk, and the -rv path has no file system to resolve a path against.
# So the source is baked in at build time.
#
# It is renamed into a private namespace on the way in. The prelude is PREPENDED
# to the user's program, so a top-level `add` in the program would shadow the
# prelude's and become what float `+` calls. See the generator for the rest.
#
#   sh scripts/gen_rv_softfloat.sh           # regenerate and commit
#   sh scripts/gen_rv_softfloat.sh --check   # fail if it would change
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/lib/rv_softfloat.ml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 "$ROOT/scripts/gen_rv_softfloat.py" "$ROOT" > "$TMP/out.ml" || exit 1

if [ "${1:-}" = "--check" ]; then
  if diff -q "$OUT" "$TMP/out.ml" >/dev/null 2>&1; then
    echo "ok gen_rv_softfloat: lib/rv_softfloat.ml matches contrib/softfloat"
    exit 0
  fi
  echo "FAIL gen_rv_softfloat: lib/rv_softfloat.ml is stale — run 'sh scripts/gen_rv_softfloat.sh'"
  diff "$OUT" "$TMP/out.ml" | head -20
  exit 1
fi

cp "$TMP/out.ml" "$OUT"
echo "gen_rv_softfloat: wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
