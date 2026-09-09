#!/bin/sh
# scripts/region_params_check.sh — how big is Q-127's remaining half, on real programs?
#
# The open half of Q-127 is that a function's body allocates through the region variable
# in its own scheme, and the call site binds a different copy: the type says the block,
# the value is in the default region. Closing it means passing the region IN as a hidden
# leading argument. v0.1.453 tried the other thing -- letting the body GUESS the runtime
# current region -- and that is unsound for a chain of calls; m3d's second frame is what
# said so, three released versions later.
#
# WHAT THIS GATE IS FOR. Before writing an ABI change, know its size from the corpus
# rather than from an impression. `mere --dump-region-params` lists, per function, how
# many region parameters it would take, and whether it CAN take them:
#
#   ok           every occurrence is a saturated call
#   value-used   the name is used as a value somewhere, so it becomes a closure, and a
#                closure's ABI has no room for a region
#   partial      every occurrence is a call but one passes too few arguments; the region
#                belongs to the saturated call
#
# Disqualified is not an error. Those keep today's behaviour (the default region), which
# is over-strict and never unsound -- so the fraction that is `ok` is the fraction of the
# problem the change would actually solve, and that is the number worth knowing.
#
# THE THREE FIXTURES ARE THE CHECK; the corpus sweep is the measurement. A gate whose
# only assertion is over a corpus that may legitimately change asserts nothing, and a
# classifier is exactly the kind of thing that quietly answers `ok` to everything: two of
# these fixtures exist so that both ways of saying "no" are seen to fire.
#
# Usage: sh scripts/region_params_check.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}
[ -x "$MERE" ] || { echo "region_params_check: $MERE not found — run dune build first" >&2; exit 1; }

fails=0
checks=0
TMPERR="$(mktemp)"
trap 'rm -f "$TMPERR"' EXIT

expect() {  # expect <fixture> <expected summary line>
  got="$("$MERE" --dump-region-params "$ROOT/test/regionparams/$1.mere" 2>&1 | grep '^#' | tail -1)"
  if [ "$got" != "$2" ]; then
    echo "FAIL region_params[$1]: expected"
    echo "    $2"
    echo "  got"
    echo "    $got"
    fails=$((fails + 1))
  fi
  checks=$((checks + 1))
}

expect ok        "# 2 region-parameterised, 2 ok, 0 value-used, 0 partial"
expect valueused "# 1 region-parameterised, 0 ok, 1 value-used, 0 partial"
expect partial   "# 1 region-parameterised, 0 ok, 0 value-used, 1 partial"
expect chain     "# 3 region-parameterised, 3 ok, 0 value-used, 0 partial"

# ---- THE CHAIN, asserted line by line --------------------------------------
#
# This is the one the rest of Q-127 turns on. `wrap` and `deep` do not allocate; they
# return what `build` made, and the call site inside each of them must read the CALLER's
# own region parameter, so the outermost block's region reaches `build`'s body by being
# handed down. If those two lines ever read `?` the propagation is gone -- and the whole
# reason the fix is a hidden argument rather than "the body asks what region is current"
# is that v0.1.453 did the latter and m3d could not render a second frame.
chain_got="$("$MERE" --dump-region-params "$ROOT/test/regionparams/chain.mere" 2>&1 | grep -e '^@' -e '^#sites')"
chain_want='@wrap -> build : ^param
@deep -> wrap : ^param
@<pattern> -> deep : ?
@<pattern> -> deep : A
#sites 1 named, 2 forwarded, 1 undecided'
if [ "$chain_got" != "$chain_want" ]; then
  echo "FAIL region_params[chain-sites]: the call sites no longer read as they must."
  echo "  want:"; printf '%s\n' "$chain_want" | sed 's/^/    /'
  echo "  got:";  printf '%s\n' "$chain_got"  | sed 's/^/    /'
  fails=$((fails + 1))
fi
checks=$((checks + 1))

# The `ok` fixture also pins that the analysis follows a call at all: `wrap` does not
# allocate, it returns what `build` made, so its scheme quantifies that region too.
if [ "$("$MERE" --dump-region-params "$ROOT/test/regionparams/ok.mere" 2>&1 | grep -c '^wrap	')" != 1 ]; then
  echo "FAIL region_params[chain]: wrap no longer takes a region parameter -- the analysis stopped following a call"
  fails=$((fails + 1))
fi
checks=$((checks + 1))

# ---- the corpus, as a measurement with a floor -----------------------------
#
# FAILURES ARE CLASSIFIED BY REASON, NOT LISTED BY NAME, and the first version of
# this got that wrong in the way that is easiest to miss: the list was written from
# what failed ON MY MACHINE. Three http examples import
# `github.com/284km/mere-markdown/...`, which resolves out of `.mere_modules/` --
# git-ignored, populated by `mere install`, present here and absent on the runner.
# So the gate passed locally and failed on CI naming three files, and the list it
# was checking against was a photograph of one machine's state.
#
# An unresolvable import is a fact about the CHECKOUT, so it is skipped and counted.
# Anything else is a fact about the PROGRAM, so it must be on the list below, which
# holds only failures that are deliberate. And an unexpected one prints the
# compiler's own first line: "stopped type-checking" without a reason cost a
# thirty-three-minute CI round trip to ask what the reason was.
#
# borrow_modes_typeerror  a type error on purpose
# brackets_balance        a lexer limit on purpose ("..." inside {...} interpolation)
# list_lib                a parse limit on purpose
# template_engine         the same lexer limit
known_skips="borrow_modes_typeerror brackets_balance list_lib template_engine"

tot=0; ok=0; vu=0; pa=0; files=0; unresolved=0
unexpected=""
for f in "$ROOT"/examples/*.mere; do
  n="$(basename "$f" .mere)"
  if out="$("$MERE" --dump-region-params "$f" 2>"$TMPERR")"; then
    # `# ` and not `^#`: the report also emits `#sites ...`, and taking the first
    # hash line silently counted the wrong one -- 289 call sites read as 289
    # value-used functions, which is the sort of number a summary line will print
    # without blinking.
    set -- $(printf '%s\n' "$out" | grep '^# ' | head -1 | sed 's/[^0-9]/ /g')
    tot=$((tot + ${1:-0})); ok=$((ok + ${2:-0})); vu=$((vu + ${3:-0})); pa=$((pa + ${4:-0}))
    files=$((files + 1))
    case " $known_skips " in *" $n "*)
      echo "FAIL region_params[$n]: listed as a known skip but it type-checks now — remove it from the list"
      fails=$((fails + 1)) ;;
    esac
  elif grep -q 'cannot resolve path' "$TMPERR"; then
    unresolved=$((unresolved + 1))
  else
    case " $known_skips " in
      *" $n "*) ;;
      *) unexpected="$unexpected $n"
         echo "  $n: $(head -1 "$TMPERR" | cut -c1-100)" ;;
    esac
  fi
done

if [ -n "$unexpected" ]; then
  echo "FAIL region_params: examples that stopped type-checking for a reason that is not a missing import and not on the known list:$unexpected"
  fails=$((fails + 1))
fi
checks=$((checks + 1))

# A sweep that examined nothing agrees with every claim.
if [ "$files" -lt 200 ]; then
  echo "FAIL region_params: only $files example(s) examined — the sweep did not run"
  fails=$((fails + 1))
fi
checks=$((checks + 1))

if [ "$fails" -gt 0 ]; then
  echo "region_params_check: $fails problem(s)"
  exit 1
fi
echo "PASS region_params_check: $checks checks — over $files examples ($unresolved skipped for an unvendored import), $tot functions would take a region parameter ($ok ok, $vu value-used, $pa partial)"
