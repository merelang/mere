#!/bin/sh
# scripts/boundary_compat_check.sh — every released version of a boundary is a
# program still running somewhere, so check them against each other.
#
# THE FAILURE THIS EXISTS FOR. The moment you deploy, clients holding the old
# code call the new server. That happens on every deploy of every app, and
# nothing in the language or the stdlib says a word about it: `to_json` /
# `of_json` are derived from a record declaration, and changing that declaration
# silently changes the wire.
#
# WHAT IT DOES. test/boundary/v<N>.mere is the boundary AS SHIPPED at version N,
# kept executable rather than described:
#
#   mere test/boundary/vN.mere encode          -> that version's payload
#   mere test/boundary/vN.mere decode <json>   -> "ok" / "fail"
#
# Every (encoder, decoder) pair is crossed, giving a matrix. The matrix is
# compared byte for byte against test/boundary/EXPECTED. A cell that changes —
# in either direction — fails the gate: a break that appears is a regression,
# and a break that disappears means the record was fixed and the note about it
# is now a lie.
#
# TWO LANES. The same change is recorded on both the derived-JSON boundary and
# on protobuf's wire, because the first one's answer is a property of the
# encoding rather than of evolution, and a matrix showing only the failure
# reads as if evolution were impossible. It is not: numbering the fields,
# defaulting an absent one and skipping an unknown one is what makes it
# possible, and none of those three is available to a name-keyed decoder.
#
# typo_cost.mere records the price of taking the second rule without the first.
#
# WHY A RECORDED MATRIX AND NOT "ALL CELLS MUST BE ok". Because measurement says
# they cannot all be ok. Mere's derived decoder requires every key to be
# PRESENT — including keys of `option` type, where `option` means the value may
# be null, not that the key may be absent (`None` encodes as `"k":null`). So
# adding a field breaks old->new, removing one breaks new->old, and there is no
# compatible change available. Pretending otherwise would make this gate red on
# arrival; recording it makes the cost visible and any change to it loud.
#
# Usage: sh scripts/boundary_compat_check.sh [--update]
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
DIR=test/boundary
EXPECTED=$DIR/EXPECTED
[ -x "$MERE" ] || { echo "boundary_compat: no compiler at $MERE (run dune build)"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

versions=$(ls "$DIR"/v*.mere 2>/dev/null | sed 's|.*/||; s|\.mere$||' | sort -V)
[ -n "$versions" ] || { echo "boundary_compat: FAIL — no versions in $DIR"; exit 1; }

# Payloads first, so a version that cannot even encode is named as that.
for v in $versions; do
  if ! "$MERE" "$DIR/$v.mere" encode > "$tmp/$v.json" 2>"$tmp/$v.err"; then
    echo "boundary_compat: FAIL — $v could not encode"; cat "$tmp/$v.err"; exit 1
  fi
  head -1 "$tmp/$v.json" > "$tmp/$v.payload"
  [ -s "$tmp/$v.payload" ] || { echo "boundary_compat: FAIL — $v encoded nothing"; exit 1; }
done

{
  echo "# produced by scripts/boundary_compat_check.sh"
  echo "#"
  echo "# The payload each version puts on the wire. Recorded because the"
  echo "# accept/reject matrix below cannot see a wire change that both sides"
  echo "# still tolerate -- found by poisoning this gate: adding a second field"
  echo "# to a version changed what it sends and moved no cell."
  for v in $versions; do
    echo "$v payload : $(cat "$tmp/$v.payload")"
  done
  echo "#"
  echo "# encoder -> decoder"
  echo "# ok   = that decoder accepts that encoder's payload"
  echo "# fail = it does not, so a client on the encoder version cannot talk"
  echo "#        to a server on the decoder version"
  for enc in $versions; do
    for dec in $versions; do
      r=$("$MERE" "$DIR/$dec.mere" decode "$(cat "$tmp/$enc.payload")" 2>/dev/null | head -1)
      case "$r" in ok|fail) ;; *) r="ERROR($r)" ;; esac
      echo "$enc -> $dec : $r"
    done
  done
} > "$tmp/matrix"

# ---- the same change, on a wire format designed for it -------------------
# The JSON lane records v1 -> v2 : fail. That is a property of the ENCODING,
# not of evolution, and the matrix says so only if the alternative is beside
# it: test/boundary/proto makes the identical field addition to a .proto and
# crosses the generated codecs. Recording both is what turns "our boundary
# cannot evolve" into a decision about encoding rather than a fact of life.
{
  echo "#"
  echo "# the identical change (one field added), on protobuf's wire:"
  "$MERE" test/boundary/proto/cross.mere 2>/dev/null | sed 's/^/# proto  /'
  echo "#"
  echo "# and what a name-keyed decoder costs if it fills absent keys instead"
  echo "# of refusing them (test/boundary/typo_cost.mere):"
  "$MERE" test/boundary/typo_cost.mere 2>/dev/null | sed 's/^/# typo   /'
} >> "$tmp/matrix"

cells=$(grep -cE '^v[^ ]* -> v[^ ]* : ' "$tmp/matrix")
if [ "$cells" -eq 0 ]; then
  echo "boundary_compat: FAIL — crossed 0 pairs (the gate did not run)"; exit 1
fi

if [ "${1:-}" = "--update" ]; then
  cp "$tmp/matrix" "$EXPECTED"; echo "boundary_compat: wrote $EXPECTED ($cells cells)"; exit 0
fi

[ -f "$EXPECTED" ] || { echo "boundary_compat: FAIL — no $EXPECTED (run with --update)"; exit 1; }

if diff -u "$EXPECTED" "$tmp/matrix" > "$tmp/d" 2>&1; then
  broken=$(grep -c ': fail' "$tmp/matrix")
  echo "boundary_compat: $cells pairs crossed, matrix unchanged ($broken recorded as incompatible)"
  exit 0
fi
echo "boundary_compat: FAIL — the compatibility matrix changed"
echo "  A cell that went ok -> fail is a break you are about to deploy.
  A changed payload line is a wire change, even if no cell moved."
echo "  A cell that went fail -> ok means the record was fixed; update $EXPECTED."
sed 's/^/  /' "$tmp/d"
exit 1
