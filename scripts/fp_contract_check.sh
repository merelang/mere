#!/bin/sh
# scripts/fp_contract_check.sh — the optimizer must not change the answer.
#
# Compiles test/float/fp_contract_probe.mere at -O0 and at -O2 and requires
# bitwise-identical output, and requires both to match the interpreter. At
# -O2, clang contracts a*b+c into fma by default on arm64 — one rounding
# where the interpreter does two — so without the emitted
# `#pragma STDC FP_CONTRACT OFF` this gate fails. Every other float gate in
# this repo compiles at -O0, where the divergence is invisible; this one
# exists BECAUSE of that blind spot (found by an MLP dogfood whose -O2
# binary disagreed with `mere run` by an ulp on 4 of 10 outputs).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "fp_contract_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "fp_contract_check: no C compiler" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

P="$ROOT/test/float/fp_contract_probe.mere"
"$MERE" "$P" > "$TMP/interp" 2>&1 || { echo "FAIL fp_contract: interp refused the probe"; exit 1; }
"$MERE" -c "$P" > "$TMP/p.c" 2>"$TMP/err" || { echo "FAIL fp_contract: mere -c"; cat "$TMP/err"; exit 1; }
"$CC" -O0 -w "$TMP/p.c" -lm -o "$TMP/p0" || { echo "FAIL fp_contract: -O0 build"; exit 1; }
"$CC" -O2 -w "$TMP/p.c" -lm -o "$TMP/p2" || { echo "FAIL fp_contract: -O2 build"; exit 1; }
o0="$("$TMP/p0")"; o2="$("$TMP/p2")"
[ "$o0" = "$o2" ] || {
  echo "FAIL fp_contract: -O0 and -O2 disagree"
  echo "--- -O0: $o0"
  echo "--- -O2: $o2"
  exit 1; }
oi="$(head -1 "$TMP/interp")"
c1="$(echo "$o0" | head -1)"
[ "$oi" = "$c1" ] || {
  echo "FAIL fp_contract: interp and C disagree"
  echo "--- interp: $oi"
  echo "--- C:      $c1"
  exit 1; }
echo "fp_contract_check: ok ($c1)"
