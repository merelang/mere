#!/bin/sh
# scripts/gen_encoding_labels.sh — the Encoding Standard's label table as Mere source.
# Needs network. Maintenance command, not a gate.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="${TMPDIR:-/tmp}/mere_enclabels.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
curl -sSf --max-time 60 https://encoding.spec.whatwg.org/encodings.json -o "$T/encodings.json"
python3 "$ROOT/scripts/gen_encoding_labels.py" "$T/encodings.json" "$ROOT/contrib/encoding/labels.mere"
echo "wrote contrib/encoding/labels.mere"
