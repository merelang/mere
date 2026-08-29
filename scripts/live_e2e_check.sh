#!/bin/sh
# scripts/live_e2e_check.sh — the live-read loop over a real socket.
#
# scripts/live_query_check.sh holds the DERIVATION to 37 cases on four
# backends. That is pure string work, and it cannot show whether the channel a
# subscriber is actually attached to is the channel a write actually
# broadcasts on: two names that agree inside the program and disagree on the
# wire look identical from in there.
#
# So this runs the loop -- registry -> derive -> broadcast -> subscriber --
# against a server on a port, with EventSource clients held open by curl.
#
# THE NEGATIVE IS THE TEST. A subscriber to `sessions` must receive NOTHING
# when `posts` is written. A broadcast-to-everyone implementation delivers the
# update to every subscriber and would pass any check that only asks "did the
# posts client get it".
#
# No database: the write path takes its statement from the request body, so
# the part under test is the wiring and there is nothing to install. A gate
# that skips in CI for want of a service is a gate that does not run.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
PORT=${PORT:-8099}
SRC=examples/live/server.mere
[ -x "$MERE" ] || { echo "live_e2e: no compiler at $MERE (run dune build)"; exit 1; }
command -v wat2wasm >/dev/null 2>&1 || { echo "live_e2e: SKIP (no wat2wasm)"; exit 0; }
command -v node >/dev/null 2>&1     || { echo "live_e2e: SKIP (no node)"; exit 0; }
command -v curl >/dev/null 2>&1     || { echo "live_e2e: SKIP (no curl)"; exit 0; }

tmp=$(mktemp -d) || exit 1
srv=""
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

"$MERE" -w "$SRC" > "$tmp/s.wat" 2>"$tmp/emit.err" || {
  echo "live_e2e: FAIL — server did not emit Wasm"; head -5 "$tmp/emit.err"; exit 1; }
wat2wasm --enable-tail-call "$tmp/s.wat" -o "$tmp/s.wasm" 2>"$tmp/wat.err" || {
  echo "live_e2e: FAIL — emitted Wasm did not assemble"; head -3 "$tmp/wat.err"; exit 1; }

node scripts/run_http_server.js "$tmp/s.wasm" > "$tmp/srv.log" 2>&1 &
srv=$!

i=0
until curl -s -m 1 "http://127.0.0.1:$PORT/registry" > "$tmp/reg" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -gt 60 ] && { echo "live_e2e: FAIL — server never answered"; cat "$tmp/srv.log"; exit 1; }
  sleep 0.3
done

fail=0
checks=0
want() {  # want <label> <expected> <actual>
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then return 0; fi
  echo "  FAIL $1: expected [$2] got [$3]"; fail=$((fail + 1))
}

# A read no write makes stale must be refused a channel, not given one it will
# never be told about: a registered subscriber that is never woken looks live.
want "registry" "size=3 agg_registered=no" "$(cat "$tmp/reg")"

# subscribers, held open
curl -s -N -m 8 "http://127.0.0.1:$PORT/sse/posts"    > "$tmp/posts.sse"    2>&1 &
curl -s -N -m 8 "http://127.0.0.1:$PORT/sse/sessions" > "$tmp/sessions.sse" 2>&1 &
sleep 2

woke=$(curl -s -X POST --data 'INSERT INTO posts (title) VALUES ($1)' \
        "http://127.0.0.1:$PORT/write" | tr -d '\n')
want "write names its channels" "posts" "$woke"
sleep 2

got_posts=$(grep -c '^data:' "$tmp/posts.sse" 2>/dev/null || true)
got_sess=$(grep -c '^data:' "$tmp/sessions.sse" 2>/dev/null || true)
want "posts subscriber woken"      "1" "${got_posts:-0}"
want "sessions subscriber left alone" "0" "${got_sess:-0}"

# both must actually have been connected -- 0 frames on a socket that was never
# open would satisfy the negative for the wrong reason
con_p=$(grep -c 'connected' "$tmp/posts.sse" 2>/dev/null || true)
con_s=$(grep -c 'connected' "$tmp/sessions.sse" 2>/dev/null || true)
want "posts subscriber was connected"    "1" "${con_p:-0}"
want "sessions subscriber was connected" "1" "${con_s:-0}"

if [ "$checks" -lt 6 ]; then
  echo "live_e2e: FAIL — only $checks checks ran"; exit 1
fi
[ "$fail" -eq 0 ] || { echo "live_e2e: FAIL — $fail of $checks checks"; exit 1; }
echo "live_e2e: $checks checks over a real socket, including the two negatives"
exit 0
