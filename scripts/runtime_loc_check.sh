#!/bin/sh
# scripts/runtime_loc_check.sh — a runtime failure has to say WHERE, and HOW THE
# PROGRAM GOT THERE.
#
# Static errors in this compiler have carried a position and a code frame for a
# long time. Runtime ones did not: `map_get: key not found in Map` was the whole
# report, which in a 30,000-line file (mere-ruby's `main.mere` is 30,392) names
# nothing. The position comes from the application node, because the builtin that
# raises is handed none of its own; the frames come from the interpreter's call
# stack.
#
# Each case in test/runtime_loc/ declares what it expects in its own header:
#
#   // env: MERE_MAX_DEPTH=40                  (optional, one assignment)
#   // expect-msg: <substring of the message>
#   // expect-loc: <line>:<col>
#   // expect-frames: name@line:col name@line:col     (innermost first)
#   // expect-frames: -                        (a failure with no frames)
#
# A repeated frame is written `name@line:col(xN)` — runaway recursion arrives
# with as many frames as the depth limit allows, and the report collapses them.
#
# Usage:
#   sh scripts/runtime_loc_check.sh            # check
#   sh scripts/runtime_loc_check.sh --poison   # check that it can go red
#
# THE POISONS (`--poison`) are two, because one is not enough to show that both
# halves of this gate are looking at anything:
#
#   1. frames off  — run the same cases with MERE_BACKTRACE=0. Every case that
#      declares frames must now FAIL. A gate that still passed would be reading
#      the message and calling it a stack.
#   2. position moved — rewrite one case's `expect-loc` to the next column and
#      require that case to FAIL. A gate that still passed would be accepting any
#      position, which is most of what there is to get wrong here.
#
# and a control: the unpoisoned run must be green, so that "red" means the poison
# and not a broken harness.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
CASES="$ROOT/test/runtime_loc"

[ -x "$MERE" ] || { echo "runtime_loc: $MERE not built" >&2; exit 2; }
[ -d "$CASES" ] || { echo "runtime_loc: $CASES missing" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/runtime_loc.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

header() { # file key -> value, empty when absent
  sed -n "s|^// $2: *||p" "$1" | head -1
}

# The gutter in front of `-->` is as wide as the largest line number in the
# frame, so it is 2 spaces at line 9 and 3 at line 10. Matching a fixed indent
# here passed on every short case and would have failed the day one grew.
actual_loc() { # stderr-file -> line:col
  sed -n 's|^ *--> [^ ]*:\([0-9][0-9]*:[0-9][0-9]*\)$|\1|p' "$1" | head -1
}

# Frames are printed after the heading, one per line, `  name at file:l:c` with
# an optional ` (x N)`. Normalised to the header's spelling so the comparison is
# between two strings a person wrote and can read.
actual_frames() { # stderr-file -> "name@l:c name@l:c" or "-"
  # Split the path off by taking the LAST TWO colon-separated fields rather than
  # by matching the path: the first version did it with one sed expression whose
  # capture groups ran together, and it turned `8:25` into `8:2(x5)` — a value
  # that looks enough like a frame to be read past.
  fr=$(awk '$2 == "at" {
              n = split($3, p, ":")
              rep = ""
              if ($4 == "(x") { c = $5; gsub(/[^0-9]/, "", c); rep = "(x" c ")" }
              printf "%s@%s:%s%s ", $1, p[n-1], p[n], rep
            }' "$1" | sed 's| *$||')
  [ -n "$fr" ] || fr="-"
  printf '%s' "$fr"
}

# $1 = "frames" to check frames too, or "loc" for position+message only.
# $2 = extra env assignment applied to every case ("" for none)
# $3 = directory of cases
# Prints one line per failing case; the count is its exit status.
run_cases() {
  _what="$1"; _extra="$2"; _dir="$3"
  _bad=0
  for f in "$_dir"/*.mere; do
    [ -f "$f" ] || continue
    _name="$(basename "$f")"
    _env="$(header "$f" env)"
    _msg="$(header "$f" expect-msg)"
    _loc="$(header "$f" expect-loc)"
    _frames="$(header "$f" expect-frames)"
    if [ -z "$_msg" ] || [ -z "$_loc" ] || [ -z "$_frames" ]; then
      echo "  $_name: header incomplete (expect-msg / expect-loc / expect-frames)"
      _bad=$((_bad + 1)); continue
    fi
    # `env` with no assignments is just `env`, which runs the command unchanged.
    # shellcheck disable=SC2086
    env $_env $_extra "$MERE" "$f" >"$tmp/out" 2>"$tmp/err"
    _rc=$?
    _problems=""
    [ "$_rc" = 1 ] || _problems="$_problems exit($_rc)"
    # grep -F: an expected message may hold regex metacharacters — `(len=2)`
    # does. And no `-q` inside a `&&` chain: a zero-count grep exits nonzero and
    # would carry the rest of the line away with it.
    if ! grep -F "$_msg" "$tmp/err" >/dev/null 2>&1; then
      _problems="$_problems msg"
    fi
    _aloc="$(actual_loc "$tmp/err")"
    [ "$_aloc" = "$_loc" ] || _problems="$_problems loc(got:${_aloc:-none} want:$_loc)"
    if [ "$_what" = frames ]; then
      _afr="$(actual_frames "$tmp/err")"
      [ "$_afr" = "$_frames" ] || _problems="$_problems frames(got:$_afr want:$_frames)"
    fi
    if [ -n "$_problems" ]; then
      echo "  $_name:$_problems"
      _bad=$((_bad + 1))
    fi
  done
  return $_bad
}

count_cases() { ls "$CASES"/*.mere 2>/dev/null | wc -l | tr -d ' '; }
# A case declaring frames is one that poison 1 must be able to break.
count_framed() {
  _n=0
  for f in "$CASES"/*.mere; do
    [ -f "$f" ] || continue
    [ "$(header "$f" expect-frames)" = "-" ] || _n=$((_n + 1))
  done
  echo $_n
}

if [ "${1:-}" = "--poison" ]; then
  fails=0

  # CONTROL first: if the clean run is not green, every "red" below is
  # meaningless and the poisons prove nothing.
  out="$(run_cases frames "" "$CASES")"; n=$?
  if [ "$n" != 0 ]; then
    echo "poison: CONTROL IS NOT GREEN — $n case(s) fail before any poison:"
    echo "$out"
    exit 1
  fi
  echo "poison: control green ($(count_cases) cases)"

  # POISON 1: the frames are switched off. Every case that declares frames must
  # now be reported, and the ones that declare none must not be.
  out="$(run_cases frames "MERE_BACKTRACE=0" "$CASES")"; n=$?
  want="$(count_framed)"
  if [ "$n" = "$want" ]; then
    echo "poison 1 (MERE_BACKTRACE=0): red on $n/$want framed cases — the gate reads frames"
  else
    echo "poison 1 (MERE_BACKTRACE=0): FAILED — expected $want red, got $n"
    echo "$out"
    fails=$((fails + 1))
  fi

  # POISON 2: one case's declared position is moved by a column. Only that case
  # may go red -- if the whole set goes red, the harness broke rather than the
  # expectation, and the poison would be proving nothing about positions.
  mkdir -p "$tmp/moved"
  cp "$CASES"/*.mere "$tmp/moved/"
  victim="$tmp/moved/map_missing.mere"
  old="$(header "$victim" expect-loc)"
  new="$(echo "$old" | awk -F: '{print $1 ":" $2 + 1}')"
  sed -i.bak "s|^// expect-loc: $old\$|// expect-loc: $new|" "$victim" && rm -f "$victim.bak"
  out="$(run_cases frames "" "$tmp/moved")"; n=$?
  if [ "$n" = 1 ]; then
    echo "poison 2 (expect-loc $old -> $new): red on exactly that case — the gate reads the position"
  else
    echo "poison 2 (expect-loc $old -> $new): FAILED — expected exactly 1 red, got $n"
    echo "$out"
    fails=$((fails + 1))
  fi

  [ "$fails" = 0 ] || exit 1
  echo "runtime_loc: poison ok (2 poisons + control)"
  exit 0
fi

out="$(run_cases frames "" "$CASES")"; n=$?
total="$(count_cases)"
if [ "$n" != 0 ]; then
  echo "runtime_loc: $n/$total case(s) failed"
  echo "$out"
  exit 1
fi
echo "runtime_loc: $total/$total ok (position + frames on every case)"

# ---------------------------------------------------------------- compiled leg
#
# The same question on the backend the big programs actually run on. There is no
# POSITION here -- the C runtime's failure helpers are handed none -- so what is
# checked is the frames, the two switches, and the one thing a trap must never
# do: fire on a failure the program caught on purpose.
#
# Skips (exit 0) without clang, the way debug_info.sh does: this asks a question
# about a compiled binary, and without a C compiler there is no binary to ask.
command -v clang >/dev/null 2>&1 || {
  echo "runtime_loc: clang not found — skipping the compiled leg"
  exit 0
}

cbad=0
csrc="$CASES/compiled/deep_chain.mere"
"$MERE" -c -g "$csrc" >"$tmp/deep.c" 2>"$tmp/emit.err" || {
  echo "runtime_loc: -c failed on $csrc"; cat "$tmp/emit.err"; exit 1; }
# -O0 on purpose: the frames are the subject, and -O2 inlines them away. That is
# not a defect being hidden -- the -O2 run below asserts the honest answer.
clang -g -O0 -o "$tmp/deep" "$tmp/deep.c" || { echo "runtime_loc: clang failed"; exit 1; }

frames_of() { # binary -> "a b c" (the printed frame names, in order)
  "$1" >/dev/null 2>"$tmp/cerr"
  awk '/^call stack/ {on=1; next} on && NF == 1 {printf "%s ", $1}' "$tmp/cerr" | sed 's| *$||'
}

want="a__direct b__direct c__direct d__direct"
got="$(frames_of "$tmp/deep")"
if [ "$got" != "$want" ]; then
  echo "  compiled frames: got [$got] want [$want]"
  cbad=$((cbad + 1))
fi

# Switched off, the block must be gone entirely -- not an empty heading. Counted
# in BYTES: `$(...)` strips trailing newlines, so a heading with nothing under it
# and no heading at all compare equal as strings.
MERE_BACKTRACE=0 "$tmp/deep" >/dev/null 2>"$tmp/cerr"
if [ "$(grep -c 'call stack' "$tmp/cerr" || true)" != "0" ]; then
  echo "  compiled frames: MERE_BACKTRACE=0 still printed a stack"
  cbad=$((cbad + 1))
fi

# -O2: the frames really are not on the stack, so the honest report has none.
# The claim being pinned is that it prints NO frames rather than wrong ones.
clang -g -O2 -o "$tmp/deep2" "$tmp/deep.c" || { echo "runtime_loc: clang -O2 failed"; exit 1; }
got2="$(frames_of "$tmp/deep2")"
if [ -n "$got2" ]; then
  echo "  compiled frames at -O2: expected none (inlined away), got [$got2]"
  cbad=$((cbad + 1))
fi

# The two switches on the exit status.
"$tmp/deep" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] || { echo "  compiled: default exit $rc, want 1"; cbad=$((cbad + 1)); }
# Through an inner `sh -c`: a shell reports a foreground job killed by a signal
# ("Trace/BPT trap: 5") on ITS OWN stderr, which no redirection on the command
# can reach. Letting the inner shell be the one that reports keeps the gate's
# output to what the gate decided.
rc=0
sh -c 'MERE_FAIL_TRAP=1 "$1" >/dev/null 2>&1' _ "$tmp/deep" 2>/dev/null || rc=$?
[ "$rc" = 133 ] || { echo "  compiled: MERE_FAIL_TRAP=1 exit $rc, want 133 (128+SIGTRAP)"; cbad=$((cbad + 1)); }
MERE_FAIL_TRAP=0 "$tmp/deep" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] || { echo "  compiled: MERE_FAIL_TRAP=0 exit $rc, want 1"; cbad=$((cbad + 1)); }

# AND THE CONTROL CASE: a caught fail is control flow. It must stay silent, add
# no frames, and not trap -- with the trap armed, which is when getting this
# wrong would cost the most.
"$MERE" -c "$CASES/compiled/caught.mere" >"$tmp/caught.c" 2>/dev/null \
  && clang -O0 -o "$tmp/caught" "$tmp/caught.c" || {
    echo "runtime_loc: could not build the caught-fail case"; exit 1; }
MERE_FAIL_TRAP=1 "$tmp/caught" >"$tmp/cout" 2>"$tmp/cerr"; rc=$?
[ "$rc" = 0 ] || { echo "  compiled: a caught fail exited $rc, want 0"; cbad=$((cbad + 1)); }
if [ "$(wc -c <"$tmp/cerr" | tr -d ' ')" != "0" ]; then
  echo "  compiled: a caught fail wrote $(wc -c <"$tmp/cerr" | tr -d ' ') bytes to stderr, want 0"
  cbad=$((cbad + 1))
fi

if [ "$cbad" != 0 ]; then
  echo "runtime_loc: $cbad compiled check(s) failed"
  exit 1
fi
echo "runtime_loc: compiled leg ok (frames at -O0, none at -O2, both switches, caught fail silent)"
