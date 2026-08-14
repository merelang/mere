#!/bin/sh
# scripts/gen_html_entities.sh — the named character references, as Mere source.
#
# 2,231 names from the standard's own entities.json. The shape is the one Q-028
# settled for the Unicode tables: fixed-width records in one string literal, sorted,
# binary-searched by index arithmetic. Fixed width is what makes the search
# possible without an index; ASCII-and-no-NUL is what makes the literal survive
# every backend.
#
# A record is 44 characters: the name without its leading `&`, space-padded to 32,
# then two code points as six hex digits each (000000 when there is only one).
# Space pads rather than NUL because a Mere str cannot carry a NUL through the
# compiled backends, and because space sorts below every character a name uses, so
# the padded order is the plain order.
#
# Needs network. Maintenance command, not a gate.
#
# Usage:
#   sh scripts/gen_html_entities.sh

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/mere_entities.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT

curl -sSf --max-time 60 https://html.spec.whatwg.org/entities.json -o "$TMP/entities.json"
python3 "$ROOT/scripts/gen_html_entities.py" "$TMP/entities.json" "$ROOT/contrib/html/entities.mere"
echo "wrote contrib/html/entities.mere"
