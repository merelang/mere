#!/bin/sh
# scripts/budget_check.sh — G-6: what a page costs, and what it owes its reader.
#
# WHAT IS NOT HERE, AND WHY. No latency threshold. Wall clock on a shared
# runner measures the runner, and scripts/bench_check.sh already says so at
# length -- a bound on it goes red for reasons that have nothing to do with the
# commit, and a bound loose enough not to would never go red at all. What is
# gated here is only what the MACHINE GETS NO VOTE ON: the size of the artifact
# the compiler produced, the size of the document the server sent, and whether
# that document carries the things a page owes someone who cannot see it.
#
# BANDS, BOTH DIRECTIONS. test/budget/BUDGETS records a floor and a ceiling per
# measurement. A reading over the ceiling is the regression everyone expects. A
# reading UNDER THE FLOOR is the one that matters more: it means the thing being
# measured stopped being built, and a gate that cannot see its subject passes
# forever. bench_check.sh learned this the same way.
#
# The accessibility checks are not a score. They are four things whose absence
# has a name: a page with no lang is read out in the wrong language, a page with
# no title is an unlabelled entry in a tab strip and a history list, an input
# with no label is a box a screen reader announces as nothing, and a form with
# no submit cannot be completed without a pointer.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
BUDGETS=test/budget/BUDGETS
PORT=${PORT:-8097}   # examples/nojs/server.mere listens here
[ -x "$MERE" ] || { echo "budget: no compiler at $MERE (run dune build)"; exit 1; }
for t in wat2wasm node curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "budget: SKIP (no $t)"; exit 0; }
done

tmp=$(mktemp -d) || exit 1
srv=""
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

fail=0; checks=0
: > "$tmp/measured"

band() {  # band <name> <value>
  checks=$((checks + 1))
  name=$1; val=$2
  echo "$name $val" >> "$tmp/measured"
  line=$(grep "^$name " "$BUDGETS" 2>/dev/null)
  if [ -z "$line" ]; then
    echo "  FAIL $name = $val has no band in $BUDGETS (run with --update)"
    fail=$((fail + 1)); return
  fi
  lo=$(echo "$line" | awk '{print $2}'); hi=$(echo "$line" | awk '{print $3}')
  if [ "$val" -gt "$hi" ]; then
    echo "  FAIL $name = $val is over its ceiling $hi"; fail=$((fail + 1))
  elif [ "$val" -lt "$lo" ]; then
    echo "  FAIL $name = $val is UNDER its floor $lo — the thing being measured"
    echo "       may have stopped being built; a gate that cannot see its subject"
    echo "       passes forever. If this is a real improvement, lower the floor."
    fail=$((fail + 1))
  fi
}

# ---- 1. the artifact the compiler produced -------------------------------
for e in authz nojs live; do
  "$MERE" -w "examples/$e/server.mere" > "$tmp/$e.wat" 2>/dev/null || {
    echo "  FAIL examples/$e/server.mere did not emit Wasm"; fail=$((fail + 1)); continue; }
  wat2wasm --enable-tail-call "$tmp/$e.wat" -o "$tmp/$e.wasm" 2>/dev/null || {
    echo "  FAIL examples/$e/server.mere did not assemble"; fail=$((fail + 1)); continue; }
  band "wasm_$e" "$(wc -c < "$tmp/$e.wasm" | tr -d ' ')"
done

# ---- 2. the document the server sent, and what it owes its reader --------
node scripts/run_http_server.js "$tmp/nojs.wasm" > "$tmp/srv.log" 2>&1 &
srv=$!
i=0
until curl -s -m 1 "http://127.0.0.1:$PORT/" > "$tmp/page.html" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "budget: FAIL — server never answered"; cat "$tmp/srv.log"; exit 1; }
  sleep 0.3
done

band "html_home" "$(wc -c < "$tmp/page.html" | tr -d ' ')"

a11y() {  # a11y <label> <condition-result>
  checks=$((checks + 1))
  [ "$2" = "ok" ] || { echo "  FAIL $1"; fail=$((fail + 1)); }
}
page=$(tr -d '\n' < "$tmp/page.html")

case "$page" in *"<html lang="*) r=ok ;; *) r=no ;; esac
a11y "the page declares no lang, so it is read out in the wrong language" "$r"

case "$page" in *"<title>"*) r=ok ;; *) r=no ;; esac
a11y "the page has no title, so it is unlabelled in a tab strip and a history list" "$r"

inputs=$(echo "$page" | grep -oE '<input[^>]*name="[^"]*"' | wc -l | tr -d ' ')
labelled=$(echo "$page" | grep -oE '<label[^>]*for="[^"]*"|aria-label="[^"]*"' | wc -l | tr -d ' ')
checks=$((checks + 1))
if [ "${inputs:-0}" -gt "${labelled:-0}" ]; then
  echo "  FAIL $inputs named inputs but $labelled labels: a box a screen reader announces as nothing"
  fail=$((fail + 1))
fi

case "$page" in *"type=\"submit\""*) r=ok ;; *) r=no ;; esac
a11y "the form has no submit control, so it cannot be completed without a pointer" "$r"

if [ "${1:-}" = "--update" ]; then
  {
    echo "# name  floor  ceiling — produced by scripts/budget_check.sh --update"
    echo "# A floor exists so that a measurement collapsing to nothing is a failure"
    echo "# rather than a pass: see the note in the script."
    while read -r n v; do
      lo=$((v - v / 10)); hi=$((v + v / 10))
      echo "$n $lo $hi"
    done < "$tmp/measured"
  } > "$BUDGETS"
  echo "budget: wrote $BUDGETS from $(wc -l < "$tmp/measured" | tr -d ' ') measurements (+/-10%)"
  exit 0
fi

[ "$checks" -ge 8 ] || { echo "budget: FAIL — only $checks checks ran"; exit 1; }
[ "$fail" -eq 0 ] || { echo "budget: FAIL — $fail of $checks"; exit 1; }
echo "budget: $checks checks — sizes inside their bands, page carries lang/title/labels/submit"
exit 0
