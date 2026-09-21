#!/bin/sh
# scripts/trailing_trim_check.sh — no harness may drop a line of its subject's
# output to compensate for what the language used to print.
#
# WHY THIS EXISTS. Until v0.1.494 every Mere program printed a trailing line
# for its own value -- `()` when main was unit. Harnesses compensated, in two
# spellings: `sed '$d'` on the captured output, and `grep -v '^()$'`. Several
# probes grew a bare `0` SENTINEL for the trim to eat, and in one case the
# sentinel had leaked into the ORACLE, which printed a matching `0`.
#
# Q-136 (v0.1.494) made a unit main print nothing. The trims stayed, and what
# they dropped stopped being noise:
#
#   proto_parity      the bytes protoc agreed with, gone -- `ours: ` empty
#   proto_gen_parity  the last line of the GENERATED SOURCE
#   render_agreement  the last element of the server's tree
#
# CI was red for seven commits across eleven steps for this one reason, and
# every one of them reproduced on a development machine. This is the check
# that says so the next time, before the push rather than after.
#
# WHAT IS FORBIDDEN
#   1. `grep -v '^()$'` anywhere. A `()` a program PRINTED is a difference the
#      gate is supposed to see; there is no longer anything else to filter.
#   2. `sed '$d'` / `head -n -1` outside the allowlist below. Each allowed use
#      names its reason here, so "why is this one allowed" has an answer that
#      does not require reading the script.
#
# THE ALLOWLIST IS NOT A TODO. These four drop a line for a reason that has
# nothing to do with what a Mere program prints when it ends:
#
#   rv_exec_check.sh       an RV binary never prints the program's own final
#                          value, so a match-except-the-last-line is a named,
#                          accepted shape -- and the WHOLE-file compare is
#                          tried first, so a real last-line difference is
#                          still a difference
#   exhaustive_check.sh    splices an arm into a GENERATED .mere, trimming the
#                          source it is rewriting, not any program's output
#   parity.sh              the diagnostic payload IS the last line on a
#                          single-sink backend; it is read, not discarded
#   live_soundness_check.sh drops the `---MARK---` line from psql output
#
# Usage:
#   sh scripts/trailing_trim_check.sh            # check
#   sh scripts/trailing_trim_check.sh --poison   # check that it can go red

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$(basename "$0")"
ALLOW="rv_exec_check.sh exhaustive_check.sh parity.sh live_soundness_check.sh"

# Comment lines are excluded, or this file's own explanation is a violation of
# it -- the removal pattern hitting its own documentation.
scan() { # <pattern> -> "file:line: text" for every non-comment, non-self hit
  grep -rn -- "$1" "$ROOT/scripts" 2>/dev/null \
    | grep -v "/$SELF:" \
    | awk -F: '{ line=$0; sub(/^[^:]*:[0-9]*:/, "", line)
                 sub(/^[ \t]+/, "", line)
                 if (substr(line, 1, 1) != "#") print }'
}

allowed() { # <path> -> 0 when the file is on the allowlist
  b=$(basename "${1%%:*}")
  for a in $ALLOW; do [ "$a" = "$b" ] && return 0; done
  return 1
}

poison="${1:-}"
if [ "$poison" = "--poison" ]; then
  # Two poisons, one per rule, each in a file that is NOT on the allowlist --
  # a gate whose allowlist swallowed everything would pass a single poison.
  p="$ROOT/scripts/.trailing_trim_poison.sh"
  printf '#!/bin/sh\n( "$MERE" x ) | sed %s > out\n' "'\$d'" > "$p"
  bad1=0; sh "$0" >/dev/null 2>&1 || bad1=1
  printf '#!/bin/sh\n"$MERE" x | grep -v %s > out\n' "'^()\$'" > "$p"
  bad2=0; sh "$0" >/dev/null 2>&1 || bad2=1
  rm -f "$p"
  if [ "$bad1" = 1 ] && [ "$bad2" = 1 ]; then
    echo "trailing_trim: poison ok — both a trim and a () filter are caught"
    exit 0
  fi
  echo "trailing_trim: POISON FAILED — trim caught=$bad1, () filter caught=$bad2"
  exit 1
fi

bad=0

# 1. the `()` filter, allowed nowhere
# Written with only `.` and `*`: BSD grep does not take `\?` in a basic
# regexp, and the first spelling of this pattern was silently matching
# nothing on macOS -- the poison is what said so.
hits=$(scan "grep .*-v .\^()")
if [ -n "$hits" ]; then
  echo "trailing_trim: a \`()\` filter is left in the tree. A \`()\` a program"
  echo "               PRINTED is a difference, not noise — compare it."
  printf '%s\n' "$hits" | sed 's/^/  /'
  bad=1
fi

# 2. the trim, allowed only where the reason is not about a Mere program's value
for pat in "sed '\$d'" "sed -e '\$d'" "head -n -1"; do
  hits=$(scan "$pat")
  [ -n "$hits" ] || continue
  printf '%s\n' "$hits" | while IFS= read -r h; do
    allowed "$h" && continue
    echo "  $h"
  done > "${TMPDIR:-/tmp}/tt.$$"
  if [ -s "${TMPDIR:-/tmp}/tt.$$" ]; then
    echo "trailing_trim: a harness drops its subject's last line, and is not on"
    echo "               the allowlist in this file. Since Q-136 that line is"
    echo "               the ANSWER, not the auto-printed unit."
    cat "${TMPDIR:-/tmp}/tt.$$"
    bad=1
  fi
  rm -f "${TMPDIR:-/tmp}/tt.$$"
done

[ "$bad" = 0 ] || exit 1
n=$(set -- $ALLOW; echo $#)
echo "trailing_trim: ok — no \`()\` filter anywhere, and the last-line trim is"
echo "               left in $n places, each named with its reason"
