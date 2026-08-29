#!/bin/sh
# scripts/authz_coverage_check.sh — G-3: no effect runs as nobody.
#
# CVE-2025-29927's shape: authorization put in a layer ALONG THE PATH is
# bypassed by input that bypasses the layer. Exposure is a property of the
# EFFECT, not of the route, and a grep for the check's name finds the call
# without showing that anything is gated by it.
#
# So this counts at runtime. examples/authz/server.mere performs every effect
# through one function that records the principal it ran as, and serves the
# ledger. The sweep calls every route with NO credentials and asserts the
# ledger stayed empty; then calls the guarded ones WITH credentials and asserts
# each effect is recorded against the right principal.
#
# THE ROUTE LIST COMES FROM THE SERVER. `GET /_routes` is derived from the same
# value the router is built from, so a route added to the program appears in
# the sweep. A list of endpoints kept in this script is a list of the ones
# somebody remembered -- and the endpoint nobody remembered is the one with the
# hole in it.
#
# A route may be `public`, and that is a declaration this gate holds it to: a
# public route that performs an effect anyway fails, because it would be an
# effect running as nobody.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
PORT=${PORT:-8098}
SRC=examples/authz/server.mere
[ -x "$MERE" ] || { echo "authz_coverage: no compiler at $MERE (run dune build)"; exit 1; }
for t in wat2wasm node curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "authz_coverage: SKIP (no $t)"; exit 0; }
done

tmp=$(mktemp -d) || exit 1
srv=""
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

"$MERE" -w "$SRC" > "$tmp/s.wat" 2>"$tmp/e" || { echo "authz_coverage: FAIL — no Wasm"; head -4 "$tmp/e"; exit 1; }
wat2wasm --enable-tail-call "$tmp/s.wat" -o "$tmp/s.wasm" 2>"$tmp/w" || {
  echo "authz_coverage: FAIL — wat2wasm"; head -3 "$tmp/w"; exit 1; }

node scripts/run_http_server.js "$tmp/s.wasm" > "$tmp/srv.log" 2>&1 &
srv=$!
i=0
until curl -s -m 1 "http://127.0.0.1:$PORT/_routes" > "$tmp/routes" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "authz_coverage: FAIL — server never answered"; cat "$tmp/srv.log"; exit 1; }
  sleep 0.3
done

routes=$(grep -c . "$tmp/routes")
[ "${routes:-0}" -ge 3 ] || { echo "authz_coverage: FAIL — server offered $routes routes; the sweep would be empty"; exit 1; }

fail=0; checks=0
note() { checks=$((checks + 1)); }

# ---- 1. every route, with no credentials, must leave the ledger empty -----
while read -r method path public; do
  [ -n "$method" ] || continue
  curl -s -o /dev/null -m 5 -X "$method" "http://127.0.0.1:$PORT$path" 2>/dev/null
  note
done < "$tmp/routes"

led=$(curl -s -m 5 "http://127.0.0.1:$PORT/_ledger")
count=$(echo "$led" | sed -n 's/^count=\([0-9]*\)$/\1/p')
checks=$((checks + 1))
if [ "${count:-x}" != "0" ]; then
  echo "  FAIL an effect ran with no principal — the ledger is not empty after an"
  echo "       unauthenticated sweep of every route:"
  echo "$led" | sed 's/^/         /'
  fail=$((fail + 1))
fi

# ---- 2. with credentials, each guarded route records ITS principal --------
while read -r method path public; do
  [ -n "$method" ] || continue
  [ "$public" = "guarded" ] || continue
  curl -s -o /dev/null -m 5 -X "$method" -H "X-Token: t-alice" "http://127.0.0.1:$PORT$path" 2>/dev/null
  note
done < "$tmp/routes"

led2=$(curl -s -m 5 "http://127.0.0.1:$PORT/_ledger")
guarded=$(awk '$3 == "guarded"' "$tmp/routes" | wc -l | tr -d ' ')
count2=$(echo "$led2" | sed -n 's/^count=\([0-9]*\)$/\1/p')
checks=$((checks + 1))
if [ "${count2:-0}" != "$guarded" ]; then
  echo "  FAIL $guarded guarded routes were called with credentials but the ledger"
  echo "       holds ${count2:-0} effects — a guarded route that performs no effect is"
  echo "       either misdeclared or silently doing nothing."
  fail=$((fail + 1))
fi

# every recorded effect must name a principal, never "-"
checks=$((checks + 1))
if echo "$led2" | grep -qE ' -$'; then
  echo "  FAIL an effect is recorded as having run as nobody:"
  echo "$led2" | grep -E ' -$' | sed 's/^/         /'
  fail=$((fail + 1))
fi

# and it must be the principal that was presented
checks=$((checks + 1))
if echo "$led2" | grep -E '^[a-z_]+ ' | grep -qvE ' alice$'; then
  echo "  FAIL an effect ran as someone other than the caller:"
  echo "$led2" | grep -E '^[a-z_]+ ' | grep -vE ' alice$' | sed 's/^/         /'
  fail=$((fail + 1))
fi

[ "$checks" -ge 6 ] || { echo "authz_coverage: FAIL — only $checks checks ran"; exit 1; }
[ "$fail" -eq 0 ] || { echo "authz_coverage: FAIL — $fail of $checks"; exit 1; }
echo "authz_coverage: $routes routes swept unauthenticated, $guarded guarded effects all named their principal ($checks checks)"
exit 0
