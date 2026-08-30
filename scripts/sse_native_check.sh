#!/bin/sh
# scripts/sse_native_check.sh -- the live push loop with no runtime under it.
#
# scripts/live_e2e_check.sh already runs subscribe -> write -> receive over a
# real socket, but on Wasm under Node: the negative it proves is proved by a
# JavaScript host. That leaves the question this gate exists for open -- can a
# Mere program hold connections open BY ITSELF -- because the answer there was
# always "node did it".
#
# Here the server is a native binary. It holds every subscriber's socket for as
# long as the subscription lasts, which means the fd has to survive the request
# that created it: `http_hijack` takes the connection out of serve_mt's hands
# so the worker neither writes a response nor closes.
#
# THE NEGATIVES ARE THE TEST, and there are two, because two different wrong
# implementations both pass a check that only asks "did the subscriber get it":
#
#   1. A broadcaster that ignores the channel delivers to everyone. So a
#      subscriber to `other` must receive NOTHING when `posts` is published.
#   2. A broadcaster that keeps one subscriber instead of a list delivers to
#      the most recent one only. That is not hypothetical -- it is what this
#      module did until `channel_recv_opt` was measured and found to BLOCK
#      (it answers None for a closed channel, not for an empty one), so the
#      pump parked in the first of two channels and never took the second
#      subscriber. So THREE subscribers on `posts` must all receive.
#
# Both negatives are poison-tested in the comments of contrib/http/sse_native.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
PORT=${PORT:-8231}
SRC=examples/sse_native/server.mere
BIN=${TMPDIR:-/tmp}/sse_native_gate.bin
OUT=${TMPDIR:-/tmp}/sse_native_gate

[ -x "$MERE" ] || { echo "sse_native: no compiler at $MERE (run dune build)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "sse_native: SKIP (no curl)"; exit 0; }
CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || { echo "sse_native: SKIP (no $CC)"; exit 0; }

rm -rf "$OUT"; mkdir -p "$OUT"
"$MERE" -c "$SRC" > "$OUT/server.c" 2>"$OUT/compile.err" || {
  echo "sse_native: FAIL -- $SRC did not compile"; sed -n '1,20p' "$OUT/compile.err"; exit 1; }
"$CC" -O1 -w "$OUT/server.c" -o "$BIN" 2>"$OUT/link.err" || {
  echo "sse_native: FAIL -- generated C did not link"; sed -n '1,20p' "$OUT/link.err"; exit 1; }

PORT=$PORT "$BIN" > "$OUT/server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null' EXIT INT TERM

# Wait for the port rather than sleeping a guessed amount: a gate that races
# the server it started reports the race, not the property.
i=0
while [ $i -lt 50 ]; do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
  i=$((i + 1)); sleep 0.1
done
[ $i -lt 50 ] || { echo "sse_native: FAIL -- server never accepted on :$PORT"; cat "$OUT/server.log"; exit 1; }

# Three subscribers on the published channel, one on another.
# Each subscriber's pid is kept so the wait below names them. A bare `wait`
# also waits for the server, which by design never exits -- that is a gate that
# hangs, and a gate that hangs is worse than one that fails, because CI reports
# a timeout instead of a property.
SUBS=""
for n in 1 2 3; do
  curl -s -N -m 8 "http://127.0.0.1:$PORT/sse/posts" > "$OUT/posts$n.txt" 2>/dev/null &
  SUBS="$SUBS $!"
done
curl -s -N -m 8 "http://127.0.0.1:$PORT/sse/other" > "$OUT/other.txt" 2>/dev/null &
SUBS="$SUBS $!"
sleep 2

curl -s -m 3 -X POST --data 'posts live-from-native' "http://127.0.0.1:$PORT/publish" >/dev/null 2>&1
# curl's own -m 8 bounds each subscriber, so this terminates even if the
# server never sends anything.
for pid in $SUBS; do wait "$pid" 2>/dev/null; done

fail=0

# `grep -c` prints 0 and EXITS 1 when nothing matches, so the obvious
# `$(grep -c ... || echo 0)` yields the two-line string "0\n0" and every
# comparison against it is a shell error, not a comparison. That is how the
# first run of this gate printed OK while the `other` assertion never executed.
count() { [ -f "$1" ] || { echo 0; return; }; grep -c "$2" "$1" 2>/dev/null | head -1 | tr -dc '0-9'; echo; }

# Positive, and negative 2 in the same assertion: every one of the three.
for n in 1 2 3; do
  got=$(count "$OUT/posts$n.txt" '^data: live-from-native')
  if [ "$got" -lt 1 ]; then
    echo "sse_native: FAIL -- subscriber $n of 3 on 'posts' received nothing"
    echo "  (a broadcaster keeping one subscriber instead of a list fails exactly here)"
    fail=1
  fi
done

# Negative 1: the unrelated channel.
stray=$(count "$OUT/other.txt" '^data:')
if [ "$stray" -ne 0 ]; then
  echo "sse_native: FAIL -- subscriber on 'other' received $stray frame(s) from a 'posts' publish"
  sed -n '1,5p' "$OUT/other.txt"
  fail=1
fi

# ---- and the subscribers are let go ---------------------------------------
#
# A broadcaster that only ever pushes onto its list leaks a descriptor per
# subscription, forever. Measured before it reaped: 20 subscribe-and-disconnect
# cycles took this server from 8 open descriptors to 28, another 20 took it to
# 48, and every publish afterwards wrote to a socket nobody was reading.
#
# The quiet channel is the half that needs the heartbeat. A subscriber is
# discovered to be gone by writing to it, so one on a channel nothing is
# published to is only reachable by the keep-alive comment the broadcaster
# sends on its own timer.
fdcount() {
  if [ -d "/proc/$1/fd" ]; then ls "/proc/$1/fd" 2>/dev/null | wc -l | tr -d ' '
  elif command -v lsof >/dev/null 2>&1; then lsof -p "$1" 2>/dev/null | grep -c .
  else echo skip; fi
}
base=$(fdcount "$SRV")
if [ "$base" = skip ]; then
  echo "sse_native: FAIL -- cannot count descriptors (no /proc and no lsof), so the"
  echo "  reaping assertion below would report success without checking anything."
  exit 1
fi

for n in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -N -m 1 "http://127.0.0.1:$PORT/sse/quiet" >/dev/null 2>&1
done
# Long enough for two heartbeats to have gone out.
sleep 6
after=$(fdcount "$SRV")
if [ "$after" -gt "$((base + 2))" ]; then
  echo "sse_native: FAIL -- 10 subscribe-and-disconnect cycles on a quiet channel left"
  echo "  $after descriptors open, up from $base. The broadcaster is not letting go of"
  echo "  sockets whose peer is gone, and the process dies at the descriptor limit."
  fail=1
fi

[ $fail -eq 0 ] || exit 1
echo "sse_native: OK -- 3/3 subscribers on 'posts' received; 'other' received 0;"
echo "  10 disconnects on a quiet channel reaped ($base -> $after descriptors); native binary, no runtime"
