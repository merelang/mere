#!/bin/sh
# scripts/escape_check.sh -- hold the region escape check to an enumerated table.
#
# WHAT THIS IS. `test/escape/ROUTES` lists every way a region-bound value can
# reach something that outlives its block, and what each entry point answers
# for it. This runs the table. It is the gate for the one claim this language
# makes that nothing else here makes: no GC, and a value cannot outlive the
# arena it was allocated in.
#
# WHY IT IS A TABLE AND NOT A LIST OF TESTS. Q-053 was a use-after-free that
# type-checked: the C backend read a length of 2,054,847,098 and segfaulted
# while the interpreter, which has no arenas, printed the right answer. It was
# found by writing one program. Writing the TABLE -- which has to have every
# cell filled in -- found two more (Q-067) and one entry-point asymmetry. A
# hole nobody has thought of is not found by testing the holes somebody has.
#
# WHAT IT CHECKS, in the order the failures matter.
#
#   1. The four compiling backends AGREE. Two backends disagreeing with nothing
#      watching is the exact shape of Q-053, so disagreement is its own verdict
#      and its own message, ahead of any comparison with the table.
#   2. Each route's compiled verdict is what the table says.
#   3. Each route's interpreter verdict is what the table says. The store-form
#      routes DIVERGE here by design -- the check runs on the compiling path
#      and not under the interpreter -- and a divergence in the table is a
#      question that keeps being asked, not a failure.
#   4. A HOLE row that stopped being a hole FAILS. A gate that silently agrees
#      with whatever the compiler currently does is not checking anything, and
#      a fixed hole has to be promoted to GATED by hand so the record says so.
#   5. `unreadable` is checked in BOTH directions. A backend listed there must
#      still refuse the program for the unrelated reason, and a backend not
#      listed must still be able to read it -- otherwise a codegen subset limit
#      creeping outward would quietly turn verdicts into non-answers.
#   6. The table and the directory match, both ways. A route file with no row
#      is untested; a row with no file is a claim about nothing.
#
# NEGATIVE TEST. Change any expected verdict in ROUTES, or delete a row, or add
# a .mere with no row: each fails a different one of the checks above.
#
# Every run is bounded (scripts/bounded.sh). A gate that hangs is worse than one
# that fails.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
ROUTES="$ROOT/test/escape/ROUTES"
BOUND="${ESCAPE_TIMEOUT:-30}"
[ -x "$MERE" ] || { echo "escape_check: $MERE not found -- run 'dune build'" >&2; exit 1; }
[ -f "$ROUTES" ] || { echo "escape_check: $ROUTES not found" >&2; exit 1; }

fails=0
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

# Answer one entry point for one program: REJECT (the escape check fired),
# ACCEPT, or UNREADABLE (refused for some other reason, or timed out).
verdict() {
  _flag="$1"; _file="$2"
  if [ "$_flag" = "-" ]; then
    sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" "$_file" >/dev/null 2>"$err"
  else
    sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" "$_flag" "$_file" >/dev/null 2>"$err"
  fi
  _rc=$?
  if [ "$_rc" -eq 0 ]; then echo ACCEPT
  elif [ "$_rc" -eq 201 ]; then echo UNREADABLE
  elif grep -q "region escape" "$err"; then echo REJECT
  else echo UNREADABLE
  fi
}

listed() {  # listed <backend> <comma-list>
  case ",$2," in *",$1,"*) return 0 ;; esac
  return 1
}

rows=0
while read -r name kind compiled interp unreadable q; do
  case "$name" in ''|\#*) continue ;; esac
  rows=$((rows + 1))
  file="$ROOT/test/escape/$name.mere"
  if [ ! -f "$file" ]; then
    echo "FAIL escape[$name]: row has no program at test/escape/$name.mere"
    fails=$((fails + 1)); continue
  fi

  # --- the four compiling backends ---
  agreed=""; disagree=0
  for be in c ll w rv; do
    v="$(verdict "-$be" "$file")"
    eval "v_$be=\$v"
    if listed "$be" "$unreadable"; then
      [ "$v" = UNREADABLE ] || {
        echo "FAIL escape[$name]: -$be is listed unreadable but answered $v -- the table is stale"
        fails=$((fails + 1)); }
      continue
    fi
    [ "$v" = UNREADABLE ] && {
      echo "FAIL escape[$name]: -$be became unreadable and is not listed as such -- a subset limit is hiding a verdict"
      fails=$((fails + 1)); disagree=1; continue; }
    if [ -z "$agreed" ]; then agreed="$v"
    elif [ "$agreed" != "$v" ]; then disagree=1
    fi
  done
  if [ "$disagree" = 1 ]; then
    echo "FAIL escape[$name]: compiling backends disagree (c=$v_c ll=$v_ll w=$v_w rv=$v_rv) -- this is the Q-053 shape"
    fails=$((fails + 1))
  elif [ -n "$agreed" ] && [ "$agreed" != "$compiled" ]; then
    if [ "$kind" = HOLE ] && [ "$agreed" = REJECT ]; then
      echo "FAIL escape[$name]: the HOLE closed ($q). Promote this row to GATED -- a table that agrees with whatever the compiler does checks nothing"
    else
      echo "FAIL escape[$name]: compiled=$agreed, table says $compiled"
    fi
    fails=$((fails + 1))
  fi

  # --- the interpreter and the type printer, which must agree with each other ---
  v_run="$(verdict - "$file")"
  v_t="$(verdict -t "$file")"
  if [ "$v_run" != "$v_t" ]; then
    echo "FAIL escape[$name]: run=$v_run but -t=$v_t -- one toolchain, two answers about one program"
    fails=$((fails + 1))
  elif [ "$v_run" != "$interp" ]; then
    echo "FAIL escape[$name]: interp=$v_run, table says $interp"
    fails=$((fails + 1))
  fi
done < "$ROUTES"

# --- the directory and the table match, the other way round ---
for f in "$ROOT"/test/escape/*.mere; do
  n="$(basename "$f" .mere)"
  grep -q "^$n[[:space:]]" "$ROUTES" || {
    echo "FAIL escape[$n]: program has no row in ROUTES -- it is not being checked"
    fails=$((fails + 1)); }
done

if [ "$fails" -gt 0 ]; then
  echo "FAIL escape_check: $fails problem(s) across $rows routes"
  exit 1
fi
holes=$(awk '$1 !~ /^#/ && NF && $2 == "HOLE"' "$ROUTES" | wc -l | tr -d " ")
echo "PASS escape_check: $rows routes, $holes open hole(s)"
