#!/bin/sh
# Race the actual interpreter helpers from two domains, then validate that an
# intentionally split read/store control is detected as double acquisition.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OCAMLOPT=${OCAMLOPT:-ocamlopt}
command -v "$OCAMLOPT" >/dev/null
LIB="$ROOT/_build/default/lib"
[ -f "$LIB/mere.cmxa" ] || { echo "ownedvec_claim: dune build must run first" >&2; exit 2; }
case "${1:-}" in ''|--poison) ;; *) echo "usage: $0 [--poison]" >&2; exit 2 ;; esac
claim_tmp=$(mktemp -d)
trap 'rm -rf "$claim_tmp"' 0
cp "$ROOT/scripts/ownedvec_claim_check.ml" "$claim_tmp/check.ml"
"$OCAMLOPT" -I +unix -I +str -I "$LIB/.mere.objs/byte" -I "$LIB/.mere.objs/native" -I "$LIB" \
  unix.cmxa str.cmxa "$LIB/mere.cmxa" "$claim_tmp/check.ml" -o "$claim_tmp/check"
sh "$ROOT/scripts/bounded.sh" 120 "$claim_tmp/check"
if [ "${1:-}" = --poison ]; then
  status=0
  sh "$ROOT/scripts/bounded.sh" 30 "$claim_tmp/check" --poison > "$claim_tmp/control" 2>&1 || status=$?
  [ "$status" -eq 1 ] && grep -q '^ownedvec_claim: DOUBLE_ACQUISITION ' "$claim_tmp/control" || {
    cat "$claim_tmp/control" >&2
    echo "ownedvec_claim: unsafe reference control was not detected" >&2
    exit 1
  }
  echo "ownedvec_claim: poison ok (controlled double acquisition detected)"
fi
