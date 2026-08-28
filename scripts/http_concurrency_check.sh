#!/bin/sh
# scripts/http_concurrency_check.sh -- the server answers requests at the same time.
#
# v0.1.340. `http_serve` is a sequential accept loop: accept, read, handle,
# write, close. Nothing said so and nothing measured it, so "Mere serves HTTP"
# was true and "Mere serves a web application" was not -- a handler doing a
# 50ms query caps the whole process at 20 requests a second.
#
# WHAT MAKES THIS MEASURABLE is a handler that is slow on purpose. With a fast
# handler a sequential loop and a worker pool finish a burst in the same time,
# and this gate would pass against the thing it exists to catch.
#
# THE SAME BINARY ANSWERS BOTH QUESTIONS. Worker count comes from the
# environment, so "1 worker" is the sequential control -- the comparison is
# between two runs of one program, not between this program and a story about
# what a sequential one would do.
#
# Skips (exit 0) without a C compiler or curl.
set -e

MERE=${MERE:-./_build/default/bin/mere.exe}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=${PORT:-18901}
DELAY=${DELAY:-400}
N=${N:-8}

command -v curl >/dev/null 2>&1 || { echo "http_concurrency_check: no curl -- skipping"; exit 0; }
if ! command -v clang >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
  echo "http_concurrency_check: no C compiler -- skipping"; exit 0
fi
CC=$(command -v clang || command -v cc)

WORK=$(mktemp -d); SRVPID=""
cleanup() { [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null; rm -rf "$WORK"; :; }
trap cleanup EXIT INT TERM

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

"$MERE" -c "$ROOT/test/http/concurrent.mere" > "$WORK/c.c"
$CC -O1 -o "$WORK/srv" "$WORK/c.c" -lm 2>"$WORK/cc.log" \
  || { echo "http_concurrency_check: link failed -- skipping"; sed -n '1,5p' "$WORK/cc.log"; exit 0; }

# $1 = workers -> prints the wall-clock seconds for N concurrent requests
burst() {
  MERE_HTTP_PORT="$PORT" MERE_HTTP_WORKERS="$1" MERE_HTTP_DELAY_MS="$DELAY" \
    "$WORK/srv" > "$WORK/srv.log" 2>&1 &
  SRVPID=$!
  curl -sS --retry 40 --retry-delay 1 --retry-connrefused --max-time 10 \
       -o "$WORK/warm" "http://127.0.0.1:$PORT/warm" >/dev/null 2>&1 || true
  s=$(now)
  i=0; pids=""
  while [ $i -lt "$N" ]; do
    curl -sS --max-time 60 -o "$WORK/r$i" "http://127.0.0.1:$PORT/r$i" 2>/dev/null &
    pids="$pids $!"
    i=$((i + 1))
  done
  # WAIT ON THE CLIENTS, NOT ON EVERY CHILD. A bare `wait` also waits for the
  # server, which never exits -- the first draft of this script hung until the
  # harness killed it, which is the failure mode a timing gate must not have.
  for p in $pids; do wait "$p" 2>/dev/null || true; done
  e=$(now)
  kill "$SRVPID" 2>/dev/null || true; SRVPID=""
  perl -e "printf '%.2f', $e - $s"
}

seq_budget=$(perl -e "printf '%.2f', $DELAY / 1000.0 * $N * 0.6")
conc=$(burst "$N")
echo "  $N concurrent requests, $DELAY ms handler, $N workers: ${conc}s"
if perl -e "exit(($conc < $seq_budget) ? 0 : 1)"; then
  ok "the pool answers them at the same time (${conc}s < ${seq_budget}s)"
else
  bad "the pool serialised them (${conc}s, expected well under ${seq_budget}s)"
fi

# All N answers must be right, not just fast: a pool that dropped or crossed
# responses would be quick.
wrong=0
i=0
while [ $i -lt "$N" ]; do
  grep -q "done GET /r$i" "$WORK/r$i" 2>/dev/null || wrong=$((wrong + 1))
  i=$((i + 1))
done
[ "$wrong" -eq 0 ] \
  && ok "every one of the $N responses is the right answer to its own request" \
  || bad "$wrong of $N responses were wrong or missing -- the pool crosses requests"

# The control: the same binary with one worker must NOT beat the budget. Without
# it, a machine fast enough to make the sleep irrelevant would pass the first
# check for the wrong reason.
one=$(burst 1)
echo "  the same binary with 1 worker: ${one}s"
if perl -e "exit(($one > $seq_budget) ? 0 : 1)"; then
  ok "one worker does serialise (${one}s) -- so the first check measured the pool"
else
  bad "one worker was also fast (${one}s); this gate is not measuring concurrency"
fi

echo
echo "http_concurrency_check: $pass passed, $fail failed, of 3 checks"
[ $((pass + fail)) -eq 3 ] || { echo "only $((pass + fail)) of 3 checks ran"; exit 1; }
[ "$fail" -eq 0 ] || exit 1
echo "http_concurrency_check: ok"
