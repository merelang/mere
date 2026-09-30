#!/bin/sh
# scripts/skip_exit_check.sh — no gate says it skipped and then exits 0.
#
# v0.1.554. A gate's exit status is its class: 0 passed, 1 failed, 2 could not
# answer (a tool is missing), 3 optional and not run (scripts/gate.sh turns it
# into 0 in CI and says so). Before this, 94 places printed "skipping" or
# "SKIP" and exited 0 -- so "passed" and "did not run" were one status, a
# runner had to read the words to tell them apart, and 65 gates could not fail
# for a missing tool (the rule came out of that). This keeps the next gate from
# writing the old shape: an `echo` that says SKIP / skipping / skip-ok, with
# `exit 0` on the same line or the next, anywhere in scripts/*.sh.
#
# A pass that counts what it left out -- "(13 skipped, no exemptions)" -- is
# not a skip, which is why the words are these three and not "skip".
#
# Usage:
#   sh scripts/skip_exit_check.sh            # check
#   sh scripts/skip_exit_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/scripts"
if [ "${1:-}" = "--poison" ]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  cp "$DIR"/*.sh "$T"/
  # ⚠ The planted probe is a path test, not the usual command-lookup builtin:
  #   tool_preflight reads that builtin's argument anywhere in scripts/ as a
  #   dependency -- in a comment too -- and the first version of this poison
  #   made CI require a tool called frob.
  printf '#!/bin/sh\n[ -x /nonexistent/frob ] || { echo "poisoned: no frob -- skipping"; exit 0; }\n' > "$T/poisoned_check.sh"
  printf '#!/bin/sh\necho "poisoned2: SKIP (no frob)"\nexit 0\n' > "$T/poisoned2_check.sh"
  DIR="$T"
fi
found=$(for f in "$DIR"/*.sh; do
  [ "$(basename "$f")" = skip_exit_check.sh ] && continue
  awk -v F="$(basename "$f")" '
    function says_skip(s) { return (s ~ /echo/ && (s ~ /SKIP/ || s ~ /[Ss]kipping/ || s ~ /skip-ok/)) }
    { if (says_skip($0) && $0 ~ /exit 0([^0-9]|$)/) print F ":" NR ": " $0
      else if (says_skip(prev) && prev !~ /exit [0-9]/ && $0 ~ /^[[:space:]]*(\}|;|fi|then)*[[:space:]]*exit 0([^0-9]|$)/) print F ":" NR-1 ": " prev
      prev = $0 }' "$f"
done)
n=$(printf '%s' "$found" | grep -c . || true)
if [ "${1:-}" = "--poison" ]; then
  printf '%s\n' "$found" | grep -q "^poisoned_check.sh:" && printf '%s\n' "$found" | grep -q "^poisoned2_check.sh:" \
    || { echo "skip_exit --poison: a skip that exits 0 was NOT caught (one line and two)"; printf '%s\n' "$found" | head -3; exit 1; }
  [ "$n" -eq 2 ] || { echo "skip_exit --poison: caught $n, want exactly the 2 planted"; printf '%s\n' "$found" | head -5; exit 1; }
  echo "skip_exit --poison: ok (both planted shapes caught, nothing else)"; exit 0
fi
if [ "$n" -gt 0 ]; then
  echo "skip_exit: $n place(s) say they skipped and exit 0 -- exit 2 (could not answer) or 3 (optional):"
  printf '%s\n' "$found" | sed 's/^/  /' | cut -c1-160
  exit 1
fi
echo "skip_exit: ok (no gate says it skipped and exits 0)"
