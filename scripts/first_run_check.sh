#!/bin/sh
# scripts/first_run_check.sh -- the path a stranger takes, as a gate.
#
# WHAT THIS IS. Everything else in scripts/ checks what the compiler does.
# This checks what the README SAYS the compiler does, by running it. It exists
# because the outward-facing surface of this project has been wrong before in
# the way that is hardest to notice: `install.sh` served a binary 260 versions
# old while every gate here was green, because no gate was pointed outward.
#
# A README is a claim. A claim nobody executes is a claim that rots.
#
# WHAT IT CHECKS.
#
#   1. Every command in the README's "Quick examples" transcript runs, and
#      where the transcript prints an expected result, that is what comes out.
#      The commands are CUT FROM README.md AT RUN TIME rather than copied here
#      -- a harness that paraphrases its subject tests the paraphrase.
#   2. Numbers the README states about the repo are derivable FROM the repo.
#      Today that is the parity program count. A number that cannot be derived
#      does not belong in a README, because nothing will ever correct it.
#   3. The first thing a newcomer does end to end, in a directory that is not
#      this one: write a program, compile it with the C backend, run it, and
#      get the same bytes the interpreter gives. This is the smallest complete
#      claim the project makes -- "you can build something with this" -- and it
#      was the only one with no gate behind it.
#
# WHAT IT DELIBERATELY DOES NOT CHECK. Whether the PUBLISHED release binary is
# current. That failure is real and this cannot see it: between two tags the
# repo is legitimately ahead of the latest release, so any per-commit version
# comparison is either always red or meaningless. It belongs in release.yml,
# where the artifact exists to be asked. Said here so the gap is recorded
# rather than assumed covered.
#
# Every run is bounded. NEGATIVE TEST: change an expected output in the README
# transcript, or the parity count, or break the C backend -- one check each.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
README="$ROOT/README.md"
BOUND="${FIRST_RUN_TIMEOUT:-60}"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "first_run_check: $MERE not found -- run 'dune build'" >&2; exit 1; }

fails=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. the README transcript, cut from the file at run time ---------------
# Lines look like:   $ dune exec ./bin/mere.exe -- <args>
# followed by either an expected stdout line, a `#` comment, or a blank line.
awk '
  /^## Quick examples/ { inblock = 1 }
  inblock && /^## / && !/^## Quick examples/ { exit }
  inblock { print }
' "$README" > "$TMP/block"

cmds=0
# Read pairs: the command line and whatever line follows it.
lineno=0
prev=""
while IFS= read -r line; do
  lineno=$((lineno + 1))
  case "$prev" in
    '$ dune exec ./bin/mere.exe -- '*)
      args="${prev#\$ dune exec ./bin/mere.exe -- }"
      cmds=$((cmds + 1))
      # eval so the transcript's own quoting is what runs
      eval "sh \"\$ROOT/scripts/bounded.sh\" \"\$BOUND\" \"\$MERE\" $args" \
        >"$TMP/out" 2>"$TMP/err"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "FAIL first_run[readme]: \`$args\` exited $rc"
        sed -n '1,2p' "$TMP/err"
        fails=$((fails + 1))
      else
        # An expected-output line is one that is neither blank, nor a comment,
        # nor the next command. Comments in the transcript describe the example
        # instead of showing its output, so they are not assertions.
        case "$line" in
          ''|'#'*|'$ '*|'```'*) : ;;
          *)
            got="$(head -1 "$TMP/out")"
            if [ "$got" != "$line" ]; then
              echo "FAIL first_run[readme]: \`$args\`"
              echo "  README says: $line"
              echo "  it printed : $got"
              fails=$((fails + 1))
            fi ;;
        esac
      fi ;;
  esac
  prev="$line"
done < "$TMP/block"

[ "$cmds" -gt 0 ] || { echo "FAIL first_run[readme]: no commands found in the Quick examples block -- the extractor stopped seeing its subject"; fails=$((fails + 1)); }

# --- 2. numbers the README states must be derivable from the repo ----------
claimed="$(sed -n 's/.*cross-backend parity (\([0-9]*\) programs).*/\1/p' "$README" | head -1)"
actual="$(ls "$ROOT"/test/parity/*.mere 2>/dev/null | wc -l | tr -d ' ')"
if [ -z "$claimed" ]; then
  echo "FAIL first_run[counts]: README no longer states a parity program count in the form this reads -- the check lost its subject"
  fails=$((fails + 1))
elif [ "$claimed" != "$actual" ]; then
  echo "FAIL first_run[counts]: README claims $claimed parity programs, test/parity holds $actual"
  fails=$((fails + 1))
fi

# --- 3. a stranger's first program, outside this directory -----------------
PROJ="$TMP/hello"
mkdir -p "$PROJ"
cat > "$PROJ/hello.mere" <<'EOM'
let greet = fn (who: str) -> "hello, " ++ who;
let total = region R {
  let v = vec_new () in
  let _ = vec_push v 20 in
  let _ = vec_push v 22 in
  vec_get v 0 + vec_get v 1
};
{
  print (greet "mere");
  print (str_of_int total)
}
EOM
if ! sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" "$PROJ/hello.mere" >"$PROJ/interp.out" 2>"$PROJ/interp.err"; then
  echo "FAIL first_run[hello]: the interpreter refused a newcomer's first program"
  sed -n '1,3p' "$PROJ/interp.err"; fails=$((fails + 1))
elif ! command -v "$CC" >/dev/null 2>&1; then
  echo "SKIP first_run[hello]: no C compiler; interpreter half ran"
else
  if ! sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" -c "$PROJ/hello.mere" >"$PROJ/hello.c" 2>"$PROJ/c.err"; then
    echo "FAIL first_run[hello]: the C backend refused it"; sed -n '1,3p' "$PROJ/c.err"; fails=$((fails + 1))
  elif ! "$CC" -O2 -w "$PROJ/hello.c" -o "$PROJ/hello" 2>"$PROJ/cc.err"; then
    echo "FAIL first_run[hello]: the emitted C did not compile"; sed -n '1,3p' "$PROJ/cc.err"; fails=$((fails + 1))
  elif ! sh "$ROOT/scripts/bounded.sh" "$BOUND" "$PROJ/hello" >"$PROJ/c.out" 2>&1; then
    echo "FAIL first_run[hello]: the compiled program exited nonzero"; fails=$((fails + 1))
  elif ! diff -q "$PROJ/interp.out" "$PROJ/c.out" >/dev/null; then
    echo "FAIL first_run[hello]: interpreter and C backend disagree on the first program"
    diff "$PROJ/interp.out" "$PROJ/c.out" | head -6; fails=$((fails + 1))
  elif ! grep -q '^42$' "$PROJ/c.out"; then
    echo "FAIL first_run[hello]: both agreed, and both are wrong -- expected 42 from the region block"
    cat "$PROJ/c.out"; fails=$((fails + 1))
  fi
fi

if [ "$fails" -gt 0 ]; then
  echo "FAIL first_run_check: $fails problem(s)"
  exit 1
fi
echo "PASS first_run_check: $cmds README commands, parity count $actual, first program agrees on both backends"
