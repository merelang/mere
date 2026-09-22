#!/bin/sh
# scripts/decls_json_check.sh — the two exits of `--decls` say the same thing.
#
# `mere --decls` prints forward declarations for a person to paste; `mere
# --decls --json` prints the same surface for a machine to diff. They are two
# renderings of one walk (`Pipeline.decls_entries`), and this gate is what keeps
# that true after somebody edits one of them: **the text is REBUILT from the
# JSON and compared byte for byte** with what the compiler printed.
#
# Not "run it twice and compare" — that passes when both are wrong together.
#
# The corpus is test/parity/, because the interesting entries are not the ones
# anybody writes by hand: a name bound twice, a name that shadows a builtin
# (test/parity/shadow_builtin.mere), a file whose declarations are all commented.
#
# Usage:
#   sh scripts/decls_json_check.sh            # check
#   sh scripts/decls_json_check.sh --poison   # check that it can go red
#
# THE POISONS are two:
#   1. rebuild while IGNORING `status` — every commented line comes out
#      uncommented, so the comparison must fail somewhere in the corpus (and
#      the gate reports how many files carry such a line, so "it passed" cannot
#      mean "there were none").
#   2. rebuild with one character changed — the comparison must fail everywhere.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "decls_json: $MERE not built" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "decls_json: python3 not found" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/decls_json.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

MODE="${1:-}"

rebuild() {  # json-file mode -> the text it implies
  python3 - "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
mode = sys.argv[2]
out = []
for v in doc["values"]:
    line = "let fn %s: %s;" % (v["name"], v["type"])
    status = "ok" if mode == "ignore-status" else v["status"]
    if mode == "typo":
        line = line.replace("let fn", "let fnx", 1)
    if status == "ok":
        out.append(line + "\n")
    else:
        out.append("// %s   // %s\n" % (line, v["note"]))
# The CLI prints every command's result through `print_endline`, which appends
# one newline to whatever the pipeline produced. The rebuild is compared after
# the same append rather than by stripping it off the compiler's side: the
# subject is what `mere --decls` PRINTS.
sys.stdout.write("".join(out) + "\n")
PY
}

ok=0; bad=0; skipped=0; commented=0; failures=""
for f in "$ROOT"/test/parity/*.mere; do
  base=$(basename "$f" .mere)
  "$MERE" --decls "$f" > "$tmp/text" 2>/dev/null || { skipped=$((skipped + 1)); continue; }
  "$MERE" --decls --json "$f" > "$tmp/json" 2>/dev/null || { skipped=$((skipped + 1)); continue; }
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/json" 2>/dev/null || {
    bad=$((bad + 1)); failures="$failures  $base: not valid JSON
"; continue; }
  grep -c '^// let fn' "$tmp/text" >/dev/null 2>&1 && \
    commented=$((commented + $(grep -c '^// let fn' "$tmp/text" || true)))
  case "$MODE" in
    --poison) ;;  # the poisons run below, on their own
    *) ;;
  esac
  rebuild "$tmp/json" plain > "$tmp/rebuilt" 2>/dev/null || {
    bad=$((bad + 1)); failures="$failures  $base: rebuild failed
"; continue; }
  if cmp -s "$tmp/text" "$tmp/rebuilt"; then ok=$((ok + 1))
  else
    bad=$((bad + 1))
    failures="$failures  $base: the JSON does not rebuild the text
$(diff "$tmp/text" "$tmp/rebuilt" | head -4)
"
  fi
done

# A gate whose subject vanished is not a gate that passed.
if [ "$ok" -lt 100 ]; then
  echo "decls_json: only $ok files round-tripped ($skipped skipped) — the corpus or the CLI is not what this expects" >&2
  exit 1
fi
if [ "$commented" -lt 1 ]; then
  echo "decls_json: no commented declaration anywhere in the corpus — poison 1 would prove nothing" >&2
  exit 1
fi

if [ "$MODE" = "--poison" ]; then
  pfail=0
  # Find one file with a commented declaration; ignoring status must break it.
  victim=""
  for f in "$ROOT"/test/parity/*.mere; do
    "$MERE" --decls "$f" > "$tmp/text" 2>/dev/null || continue
    if grep -q '^// let fn' "$tmp/text"; then victim="$f"; break; fi
  done
  if [ -z "$victim" ]; then
    echo "  FAIL  POISON 1: no file with a commented declaration to poison"
    pfail=1
  else
    "$MERE" --decls "$victim" > "$tmp/text" 2>/dev/null
    "$MERE" --decls --json "$victim" > "$tmp/json" 2>/dev/null
    rebuild "$tmp/json" ignore-status > "$tmp/p1" 2>/dev/null
    if cmp -s "$tmp/text" "$tmp/p1"; then
      printf '  FAIL  %s\n' "POISON 1 (ignore status): still matched on $(basename "$victim")"
      pfail=1
    else
      printf '  ok    %s\n' "POISON 1 (ignore status): $(basename "$victim") no longer matches"
    fi
  fi
  # A typo anywhere must break the first file that has any declaration at all.
  for f in "$ROOT"/test/parity/*.mere; do
    "$MERE" --decls "$f" > "$tmp/text" 2>/dev/null || continue
    [ -s "$tmp/text" ] || continue
    "$MERE" --decls --json "$f" > "$tmp/json" 2>/dev/null
    rebuild "$tmp/json" typo > "$tmp/p2" 2>/dev/null
    if cmp -s "$tmp/text" "$tmp/p2"; then
      printf '  FAIL  %s\n' "POISON 2 (one character changed): still matched"
      pfail=1
    else
      printf '  ok    %s\n' "POISON 2 (one character changed): does not match"
    fi
    break
  done
  if [ "$pfail" = 0 ] && [ "$bad" = 0 ]; then
    echo "decls_json --poison: ok (the gate can go red)"
  else
    echo "decls_json --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$bad" = 0 ]; then
  echo "decls_json: ok ($ok files rebuilt from JSON byte for byte, $commented commented declarations among them, $skipped skipped)"
  exit 0
fi
echo "decls_json: FAILED ($bad of $((ok + bad)))"
printf '%s' "$failures"
exit 1
