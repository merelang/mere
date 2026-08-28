#!/bin/sh
# scripts/downstream_check.sh -- the programs written in this language still
# parse and type against the compiler in this tree.
#
# WHAT THIS IS. Mere has around three dozen dogfood repositories, none of them
# with CI, and this repository could not see any of them. An upstream language
# change broke them silently and the news arrived whenever somebody next opened
# that repo. test/downstream/REPOS names one per language surface and this runs
# them.
#
# THE CHECK IS `mere -c <entry>` FROM INSIDE THE REPO: parse, resolve every
# import, type the whole program, and emit C. Deliberately not "the project
# works" -- it does not run their tests, and each repo owns that question.
#
# IT WAS `-t` UNTIL v0.1.336. A codegen refusal introduced in v0.1.333 stopped
# mere-ruby compiling and this gate said nothing, because typing is not where
# that failure lives; v0.1.335 shipped with it. Emitting is the wider question
# and costs 43 seconds for all twelve.
#
# SKIPS LOUDLY. Point MERE_DOWNSTREAM at a directory holding the checkouts.
# Without it, or for a repo that is not there, the row is reported as skipped
# and counted -- never silently dropped, because a gate that quietly checks
# nothing reports the same success as one that checked everything.
#
# NEGATIVE TEST: point a row's entry at a file that does not exist, or break
# something upstream and watch which row names the surface.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
TABLE="$ROOT/test/downstream/REPOS"
BOUND="${DOWNSTREAM_TIMEOUT:-180}"
DIR="${MERE_DOWNSTREAM:-}"
[ -x "$MERE" ] || { echo "downstream_check: $MERE not found -- run 'dune build'" >&2; exit 1; }
[ -f "$TABLE" ] || { echo "downstream_check: $TABLE not found" >&2; exit 1; }

if [ -z "$DIR" ]; then
  echo "downstream_check: SKIP (set MERE_DOWNSTREAM=<dir of checkouts>) -- 0 of $(awk '$1 !~ /^#/ && NF && $3 == "compile"' "$TABLE" | wc -l | tr -d ' ') repos checked"
  exit 0
fi

fails=0; ran=0; skipped=0; deferred=0
err="$(mktemp)"; trap 'rm -f "$err"' EXIT

while read -r repo entry check rest; do
  case "$repo" in ''|\#*) continue ;; esac
  case "$check" in
    deps)
      # NOTHING SELECTS THIS ROW TODAY. It existed for mbigfmt, whose imports
      # come from another repository -- and the reason ("needs `mere install`
      # first") stopped being true when the CI step started running
      # `mere install` after each clone. A skip outlives its reason silently,
      # so the row was retired rather than left saying something false. The
      # branch stays because the next such repo will want it; if it is still
      # unselected when someone reads this, delete it.
      deferred=$((deferred + 1))
      echo "  defer $repo — $rest"
      continue ;;
    compile) : ;;
    *)
      echo "FAIL downstream[$repo]: unknown check \`$check\` (want compile or deps)"
      fails=$((fails + 1)); continue ;;
  esac

  if [ ! -d "$DIR/$repo" ]; then
    skipped=$((skipped + 1))
    echo "  skip  $repo (not in \$MERE_DOWNSTREAM)"
    continue
  fi
  if [ ! -f "$DIR/$repo/$entry" ]; then
    echo "FAIL downstream[$repo]: entry $entry does not exist -- the row names a file that is gone"
    fails=$((fails + 1)); continue
  fi
  # RESOLVE DEPENDENCIES IF THEY ARE NOT THERE, so that this gate answers the
  # same question on a fresh clone and on a development checkout. It did not:
  # CI cloned each repo and compiled it, and four repos were reported as "no
  # longer compiles" for a missing .mere_modules while passing here, where one
  # already existed. Putting the step in the workflow file instead of here
  # would have left the two able to drift apart again -- the harness belongs
  # with the gate, not beside it.
  #
  # Only when .mere_modules is ABSENT: an existing one is the developer's, and
  # `mere install` would rewrite their mere.lock underneath them.
  if [ -f "$DIR/$repo/mere.toml" ] && [ ! -d "$DIR/$repo/.mere_modules" ]; then
    ( cd "$DIR/$repo" && "$MERE" install ) >"$err" 2>&1 \
      || echo "  note  $repo -- mere install failed; the check below says what broke"
  fi
  ran=$((ran + 1))
  if ( cd "$DIR/$repo" && sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" -c "$entry" > /dev/null >/dev/null 2>"$err" ); then
    echo "  ok    $repo ($entry)"
  else
    echo "FAIL downstream[$repo]: $entry no longer compiles against this compiler"
    echo "        $rest"
    sed -n '1,3p' "$err" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
done < "$TABLE"

if [ "$fails" -gt 0 ]; then
  echo "downstream_check: $fails failed, $ran checked, $skipped absent, $deferred deferred"
  exit 1
fi
echo "downstream_check: $ran checked, $skipped absent, $deferred deferred"
