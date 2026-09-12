#!/bin/sh
# scripts/wasm_size_check.sh -- what the playground actually ships, in bytes.
#
# WHY THIS EXISTS. contrib/site/build_full.sh compiles every playground demo
# to .wasm and the docs site serves those files to browsers. Nothing measured
# them. Between 2026-07 and 2026-09 hello.wasm went from 5.2 KB to 15.0 KB --
# roughly tripled -- and no run, gate or review said a word, because the size
# of a build output is not something any other check looks at.
#
# WHAT IT MEASURES. Every .wasm the real site build produces, against a band
# in scripts/wasm_size_budget.txt. The bands are not targets; they are "this is
# where it was, plus room to breathe in both directions".
#
# BANDS, NOT CEILINGS -- the design is scripts/budget_check.sh's, and the floor
# is the half that matters more. A reading over the ceiling is the regression
# everyone expects. A reading UNDER THE FLOOR means the demo stopped being
# built properly -- a stub, a truncated emit, a compiler that silently dropped
# the program -- and a gate watching only the ceiling calls that a pass, and
# keeps calling it a pass forever.
#
# WHY THIS IS NOT IN budget_check.sh. Same design, different subject and a
# different order of cost: budget_check runs in about a second, and this has to
# compile selfhost-compile.mere, which is most of a minute. Folding this in
# would make a fast gate fifty times slower for everything it already covers.
# The subjects do not overlap -- budget_check measures three example servers,
# this measures what the public site hands a browser.
#
# THE FLOOR IS THE NUMBER THAT MOVES EVERYTHING. Every program carries the
# same prelude, so the smallest demo measures a cost that all of them pay: at
# the time of writing, hello.wasm and fibonacci.wasm are both ~152 functions
# and ~12.7 KB of code section while doing almost nothing. The report prints
# that floor separately, because a change there moves fifteen files at once
# and reading it per-file makes it look like fifteen small regressions.
#
# IT BUILDS ITS OWN SUBJECT. It never measures _site/: that directory is
# gitignored and can be months old. Measuring a stale tree is how the first
# pass at this got numbers from a build two months behind HEAD, and read a
# tripling as "comfortably small".
#
# IT ALSO REPORTS SLACK. A file well under its ceiling prints a `lower it`
# line. A gate that only notices growth lets an improvement be absorbed
# silently, and the ceiling stops meaning anything.
#
# IT ALSO RUNS WHAT IT MEASURED. wasm-opt -Oz is part of the site build now, so
# this checks the optimizer did not change the answer: the shipped module is run
# and judged against the interpreter. Nothing else covers that -- parity.sh
# compiles its own programs and never sees these.
#
# SKIPS LOUDLY, NEVER VACUOUSLY. A missing wat2wasm prints a skip and exits 0.
# But a run that measured zero files, or ran zero of them, is a FAIL: an empty
# check is not a pass.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
# Overridable so the gate's own failure arms can be poisoned without editing
# the real budget: a check nobody has watched fail is a check nobody has seen.
BUDGET="${WASM_SIZE_BUDGET:-$ROOT/scripts/wasm_size_budget.txt}"

[ -x "$MERE" ] || { echo "wasm_size_check: $MERE not found -- run 'dune build'" >&2; exit 1; }
command -v wat2wasm >/dev/null 2>&1 || { echo "wasm_size_check: SKIP (no wat2wasm)"; exit 0; }
# The bands are for the OPTIMIZED build -- build_full.sh runs wasm-opt -Oz, and
# that is about a third of the shipped bytes. Measuring an unoptimized build
# against them would fail every file for a reason that is not a regression, so
# this skips rather than reporting a number about a different artifact.
command -v wasm-opt >/dev/null 2>&1 || { echo "wasm_size_check: SKIP (no wasm-opt; the bands are for the -Oz build the site ships)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "wasm_size_check: SKIP (no node; the behaviour half cannot run)"; exit 0; }

# Not just "is node here" but "can this node load what Mere emits". Every
# playground module uses return_call (opcode 0x12), which node only accepts
# unflagged from 22 on. Without this probe an old node makes the behaviour half
# report "the optimized module does not answer what the interpreter does" --
# naming the optimizer for something node refused to load. A failure that
# accuses the wrong tool is worse than no check, so the precondition is asked
# here, next to the other tool guards, rather than diagnosed from the symptom.
probe="$(mktemp -d)"
cat > "$probe/t.wat" <<'WAT'
(module (func $a (result i32) (i32.const 1))
        (func (export "m") (result i32) (return_call $a)))
WAT
if ! wat2wasm --enable-tail-call "$probe/t.wat" -o "$probe/t.wasm" 2>/dev/null \
   || ! node -e 'new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))' "$probe/t.wasm" 2>/dev/null; then
  rm -rf "$probe"
  echo "wasm_size_check: SKIP (this node cannot load a tail-call module; needs node 22+, have $(node --version))"
  exit 0
fi
rm -rf "$probe"
[ -f "$BUDGET" ] || { echo "wasm_size_check: $BUDGET not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The optimizer version is part of the measurement, not part of the machine:
# these are byte counts, and a different wasm-opt produces different bytes. A
# mismatch is not made a failure -- that would block anyone on another build --
# but it is said out loud, so a band failure is not misread as a regression.
want_opt="$(awk '/^# wasm-opt:/ { print $3 }' "$BUDGET")"
have_opt="$(wasm-opt --version 2>/dev/null | awk '{ print $3 }')"
if [ -n "$want_opt" ] && [ "$want_opt" != "$have_opt" ]; then
  echo "wasm_size_check: NOTE -- bands were recorded with wasm-opt $want_opt, this is $have_opt."
  echo "                 Band failures below may be the optimizer rather than the code."
fi

# FAIL, not SKIP. The other tool guards above skip because those tools can
# reasonably be absent; dune cannot -- anything that produced the mere.exe this
# gate already requires was built with it. Skipping here would mean that
# dropping `opam exec --` from the CI step turns this gate off without a word,
# which is the failure mode it exists to prevent elsewhere.
if ! command -v dune >/dev/null 2>&1; then
  echo "FAIL wasm_size_check: no dune on PATH, and contrib/site/build_full.sh opens with"
  echo "  \`dune exec mere -- install\`. In CI, run this step under \`opam exec --\`,"
  echo "  the way pages.yml invokes the same script."
  exit 1
fi

echo "wasm_size_check: building the site (this is the real build, not a paraphrase)"
# build_full.sh opens with `dune exec mere -- install`, so it needs dune on
# PATH -- which in CI means running this step under `opam exec --`, the way
# pages.yml invokes the same script. Named here because the first CI run of
# this gate said only "the site build failed" over a one-line `dune: not
# found`, and a build failure has many more likely causes than that one.

if ! PATH="$ROOT/_build/default/bin:$PATH" sh "$ROOT/contrib/site/build_full.sh" \
       "$ROOT/docs" "$TMP/site" >"$TMP/build.log" 2>&1; then
  echo "FAIL wasm_size_check: the site build failed"
  tail -20 "$TMP/build.log"
  exit 1
fi

PG="$TMP/site/playground"
[ -d "$PG" ] || { echo "FAIL wasm_size_check: the build produced no playground/"; exit 1; }

checked=0
fails=0
slack=0
floor_name=''
floor_size=0

printf '\n%-26s %9s %9s %9s\n' 'file' 'bytes' 'floor' 'ceiling'
printf -- '------------------------------------------------------------------\n'

for f in "$PG"/*.wasm; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  size="$(wc -c < "$f" | tr -d ' ')"

  # Before the budget lookup, not after: a file with no ceiling still ships,
  # so it still counts toward the floor. Tracking this below the `continue`
  # made the gate name the second-smallest file as the floor, which a poison
  # run caught and ordinary runs never would have.
  if [ "$floor_size" -eq 0 ] || [ "$size" -lt "$floor_size" ]; then
    floor_size="$size"
    floor_name="$name"
  fi

  floor="$(awk -v n="$name" '$1 == n { print $2 }' "$BUDGET")"
  ceiling="$(awk -v n="$name" '$1 == n { print $3 }' "$BUDGET")"
  if [ -z "$ceiling" ]; then
    printf '%-26s %9s %9s %9s   NO BUDGET LINE\n' "$name" "$size" '-' '-'
    echo "FAIL wasm_size_check: $name ships with no recorded band -- add it to $(basename "$BUDGET")"
    fails=$((fails + 1))
    checked=$((checked + 1))
    continue
  fi

  checked=$((checked + 1))
  printf '%-26s %9s %9s %9s' "$name" "$size" "$floor" "$ceiling"

  if [ "$size" -gt "$ceiling" ]; then
    printf '   OVER by %s B\n' "$((size - ceiling))"
    fails=$((fails + 1))
  elif [ "$size" -lt "$floor" ]; then
    printf '   UNDER by %s B\n' "$((floor - size))"
    echo "     a demo this much smaller than recorded probably stopped being"
    echo "     built properly. If it is a real improvement, lower the band."
    fails=$((fails + 1))
  else
    printf '\n'
    head="$(awk -v s="$size" -v c="$ceiling" 'BEGIN { printf "%.0f", (c - s) * 100 / c }')"
    [ "$head" -gt 25 ] && slack=$((slack + 1))
  fi
done

# Every budget line must have a file. A demo that is renamed or dropped leaves
# a line behind that checks nothing, and the file count keeps looking right.
while read -r bname bceil; do
  case "$bname" in ''|\#*) continue ;; esac
  : "$bceil"
  if [ ! -f "$PG/$bname" ]; then
    echo "FAIL wasm_size_check: $bname has a band but the build produced no such file"
    fails=$((fails + 1))
  fi
done < "$BUDGET"

# --- the optimizer must not have changed the answer ------------------------
# wasm-opt -Oz now runs inside build_full.sh, on the modules the public site
# hands people, and nothing else in this tree checks that it preserved
# behaviour -- parity.sh compiles its own programs and never sees these. So the
# shipped artifact is run and judged against the interpreter, which is the
# oracle parity uses. Only the demos that need no DOM and no stdin can be run
# this way; the list is fixed rather than discovered, and an empty one is a
# FAIL, because a behaviour check with nothing in it is not a check.
runnable='hello fibonacci fizzbuzz'
ran=0
agreed=0
for d in $runnable; do
  [ -f "$PG/$d.wasm" ] || { echo "FAIL wasm_size_check: $d.wasm was not built"; fails=$((fails + 1)); continue; }
  want="$("$MERE" "$ROOT/contrib/site/playground/$d.mere" 2>&1)"
  got="$(node "$ROOT/scripts/run_wasm.js" "$PG/$d.wasm" 2>&1)"
  ran=$((ran + 1))
  if [ "$want" = "$got" ]; then
    agreed=$((agreed + 1))
  else
    echo "FAIL wasm_size_check[$d]: the optimized module does not answer what the interpreter does"
    echo "  interp: $(printf '%s' "$want" | head -c 120)"
    echo "  wasm  : $(printf '%s' "$got" | head -c 120)"
    fails=$((fails + 1))
  fi
done
if [ "$ran" -eq 0 ]; then
  echo "FAIL wasm_size_check: ran 0 modules -- the behaviour check covered nothing"
  fails=$((fails + 1))
else
  # Counted, not assumed: a summary that says "3 agree" while one of them just
  # failed above is a line stating something the run disproved.
  echo "behaviour: $agreed of $ran optimized module(s) answer what the interpreter does"
fi

echo
if [ "$checked" -eq 0 ]; then
  echo "FAIL wasm_size_check: measured 0 files -- the build produced no .wasm"
  exit 1
fi

total="$(cat "$PG"/*.wasm | wc -c | tr -d ' ')"
echo "floor: $floor_name at $floor_size B -- every demo pays this before doing anything"
echo "total: $total B across $checked files"
[ "$slack" -gt 0 ] && echo "slack: $slack file(s) sit more than 25% under ceiling; the bands are stale"

if [ "$fails" -gt 0 ]; then
  echo "wasm_size_check: FAIL ($fails)"
  exit 1
fi
echo "wasm_size_check: ok ($checked files)"
