#!/bin/sh
# scripts/section_coverage.sh -- every hand-written runtime section has a
# program that reaches it, on every compiling backend.
#
# WHAT THIS IS. Parts of each backend's runtime are emitted as literal text --
# WAT, C, LLVM IR -- and gated behind a flag only a program using that feature
# sets. Text that is never emitted is never validated, never linked and never
# run, so a representation change walks past it and nothing goes red. Q-068 and
# Q-069 were both that, in sections wrong since values widened.
#
# WHAT IT CHECKS.
#
#   1. Every gated section in lib/codegen_{wasm,c,llvm}.ml has a row in
#      test/parity/SECTIONS. A section nobody wrote down is a section nobody
#      decided about, and the list is read FROM THE COMPILER SOURCE at run time
#      rather than copied here -- so a new gated section fails on the commit
#      that adds it.
#   2. Each row's named program, compiled the way the row says it is reached,
#      actually emits the section. Naming a program that does not reach it is
#      the failure this exists to prevent.
#   3. For the three modes the parity corpus itself compiles in (wasm / c /
#      llvm), the section must also be reached by SOME parity program.
#   4. `component` rows name a program built with `-w --component`, the only
#      way three of these sections can be reached. Running them is
#      scripts/component_parity.sh's job; this checks they are emitted.
#   5. `none` rows must still be unreachable. If a parity program starts
#      emitting one, the row says something untrue and the gate asks for a
#      mode rather than passing quietly.
#
# NEGATIVE TEST: delete a row; point a row at a program that does not reach its
# section; declare a component-only section as `wasm`; add a gated section to a
# backend without a row.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
TABLE="$ROOT/test/parity/SECTIONS"
BOUND="${SECTION_TIMEOUT:-90}"
[ -x "$MERE" ] || { echo "section_coverage: $MERE not found -- run 'dune build'" >&2; exit 1; }
[ -f "$TABLE" ] || { echo "section_coverage: $TABLE not found" >&2; exit 1; }

fails=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. the compiler's gated sections all have rows --------------------------
# Wasm gates by flag (`if not !flag then "" else`); C and LLVM gate by section
# name (`if !flag then [section; ""]`), and a section name is what a row can be
# keyed on there because one flag can guard several and one section name is
# unique per backend.
{
  sed -n 's/.*if not !\([a-z_][a-z_]*\) then "" else.*/\1/p' "$ROOT/lib/codegen_wasm.ml"
  sed -n 's/.*if ![a-z_!| ]* then \[\([a-z_][a-z_0-9]*\).*/c:\1/p' "$ROOT/lib/codegen_c.ml"
  sed -n 's/.*if ![a-z_!| ]* then \[\([a-z_][a-z_0-9]*\)_llvm.*/llvm:\1/p' "$ROOT/lib/codegen_llvm.ml"
} | sort -u > "$TMP/keys"
[ -s "$TMP/keys" ] || { echo "FAIL section_coverage: no gated sections found -- the extractor lost its subject"; exit 1; }
while read -r key; do
  grep -q "^$key[[:space:]]" "$TABLE" || {
    echo "FAIL section_coverage[$key]: gated section has no row in test/parity/SECTIONS"
    fails=$((fails + 1)); }
done < "$TMP/keys"

# --- compile the corpus once per mode ---------------------------------------
for mode in wasm c llvm; do
  case "$mode" in wasm) fl=-w ;; c) fl=-c ;; llvm) fl=-ll ;; esac
  n=0
  for f in "$ROOT"/test/parity/*.mere; do
    b="$(basename "$f" .mere)"
    if sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" "$fl" "$f" > "$TMP/$mode.$b" 2>/dev/null; then
      n=$((n + 1))
    else rm -f "$TMP/$mode.$b"; fi
  done
  eval "emitted_$mode=\$n"
done
[ "$emitted_wasm" -gt 0 ] || { echo "FAIL section_coverage: no parity program emitted Wasm -- nothing was measured"; exit 1; }

rows=0
while read -r key marker mode prog; do
  case "$key" in ''|\#*) continue ;; esac
  rows=$((rows + 1))
  case "$mode" in
    wasm|c|llvm|component)
      if [ ! -f "$ROOT/$prog" ]; then
        echo "FAIL section_coverage[$key]: row names $prog, which does not exist"
        fails=$((fails + 1)); continue
      fi
      case "$mode" in
        component) sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" -w --component "$ROOT/$prog" > "$TMP/named" 2>/dev/null ;;
        wasm)      sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" -w  "$ROOT/$prog" > "$TMP/named" 2>/dev/null ;;
        c)         sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" -c  "$ROOT/$prog" > "$TMP/named" 2>/dev/null ;;
        llvm)      sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" -ll "$ROOT/$prog" > "$TMP/named" 2>/dev/null ;;
      esac
      grep -q "$marker" "$TMP/named" || {
        echo "FAIL section_coverage[$key]: $prog does not emit \`$marker\` under mode $mode"
        fails=$((fails + 1)); }
      # The three modes the corpus itself compiles in must also be reached by it.
      if [ "$mode" != component ]; then
        if ! grep -l "$marker" "$TMP/$mode."* >/dev/null 2>&1; then
          echo "FAIL section_coverage[$key]: mode $mode and no parity program emits \`$marker\`"
          fails=$((fails + 1))
        fi
      fi ;;
    none)
      for m in wasm c llvm; do
        if grep -l "$marker" "$TMP/$m."* >/dev/null 2>&1; then
          echo "FAIL section_coverage[$key]: marked unreachable but reached under $m -- give it a mode"
          fails=$((fails + 1)); break
        fi
      done ;;
    *)
      echo "FAIL section_coverage[$key]: unknown mode \`$mode\` (want wasm, c, llvm, component or none)"
      fails=$((fails + 1)) ;;
  esac
done < "$TABLE"

if [ "$fails" -gt 0 ]; then
  echo "FAIL section_coverage: $fails problem(s) across $rows rows"
  exit 1
fi
comp=$(awk '$1 !~ /^#/ && NF && $3 == "component"' "$TABLE" | wc -l | tr -d ' ')
none=$(awk '$1 !~ /^#/ && NF && $3 == "none"' "$TABLE" | wc -l | tr -d ' ')
echo "PASS section_coverage: $rows sections ($comp component-only, $none unreachable); parity compiled wasm=$emitted_wasm c=$emitted_c llvm=$emitted_llvm"
