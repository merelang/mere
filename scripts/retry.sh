#!/bin/sh
# Retry an idempotent dependency installation once; retain the final status.
set -eu
[ "$#" -gt 0 ] || { echo "usage: retry.sh command [argument ...]" >&2; exit 2; }
if "$@"; then
  exit 0
else
  status=$?
fi
# Command lookup failures and interrupted jobs stop immediately.
[ "$status" -lt 126 ] || exit "$status"
echo "Dependency command failed; retrying once in 5 seconds" >&2
sleep 5
exec "$@"
