#!/bin/sh
# scripts/gate.sh — run a gate, and let an optional one say it did not run.
#
#   sh scripts/gate.sh scripts/<gate>.sh [args...]
#
# The gates' exit statuses are classes (v0.1.554): 0 passed, 1 failed, 2 could
# not answer (a tool it needs is missing), 3 is optional and was not run here,
# 201 timed out (scripts/bounded.sh). A CI step fails on anything but 0, and an
# optional gate that is not set up on a runner is not a failure -- so the
# workflow runs those gates through this, which turns 3 into 0 and says so in
# the log. Everything else passes through unchanged: a 2 in CI is a runner
# without a tool tool_preflight said it has, and that is red.
#
# Before v0.1.554 a gate that could not run printed "skipping" and exited 0, so
# "passed" and "did not run" had one exit status; 65 gates could not fail for a
# missing tool, and a runner reading the status could not tell.
set -u
[ $# -ge 1 ] || { echo "usage: sh scripts/gate.sh scripts/<gate>.sh [args...]" >&2; exit 2; }
sh "$@"
s=$?
if [ "$s" -eq 3 ]; then
  echo "gate: $1 is optional and did not run here (exit 3) -- not a failure"
  exit 0
fi
exit "$s"
