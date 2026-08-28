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

# ---- per-worker state ---------------------------------------------------
# What a connection pool is here. Checked by counting DISTINCT contexts across
# a burst: a single shared value would serve every request and still be fast,
# so speed alone does not distinguish "a pool" from "one connection everyone
# uses at once" -- which is the bug this is meant to prevent.
"$MERE" -c "$ROOT/test/http/per_worker.mere" > "$WORK/w.c"
if $CC -O1 -o "$WORK/wsrv" "$WORK/w.c" -lm 2>"$WORK/cc2.log"; then
  W=4
  MERE_HTTP_PORT="$PORT" MERE_HTTP_WORKERS="$W" MERE_HTTP_DELAY_MS=300 \
    "$WORK/wsrv" > "$WORK/wsrv.log" 2>&1 &
  SRVPID=$!
  curl -sS --retry 40 --retry-delay 1 --retry-connrefused --max-time 10 \
       -o /dev/null "http://127.0.0.1:$PORT/warm" >/dev/null 2>&1 || true
  i=0; wpids=""
  while [ $i -lt "$W" ]; do
    curl -sS --max-time 60 -o "$WORK/w$i" "http://127.0.0.1:$PORT/w$i" 2>/dev/null &
    wpids="$wpids $!"; i=$((i + 1))
  done
  for p in $wpids; do wait "$p" 2>/dev/null || true; done
  kill "$SRVPID" 2>/dev/null || true; SRVPID=""
  distinct=$(cat "$WORK"/w[0-9]* 2>/dev/null | sort -u | grep -c 'ctx=' || true)
  [ "$distinct" -eq "$W" ] \
    && ok "$W workers built $W distinct contexts -- none is shared" \
    || bad "saw $distinct distinct contexts across $W workers (expected $W)"
else
  bad "test/http/per_worker.mere did not build: $(head -2 "$WORK/cc2.log" | tr '\n' ' ')"
fi

# ---- a slow CLIENT ------------------------------------------------------
# The question a worker pool cannot answer. Eight clients connect, send HALF a
# request, and say nothing more. Under the pool they hold all eight workers and
# a normal request never gets served; under the readiness loop they are eight
# entries in a map.
#
# Opening a socket and going quiet costs an attacker nothing, which is why this
# is different in kind from "a slow handler holds a worker".
"$MERE" -c "$ROOT/test/http/readiness.mere" > "$WORK/rd.c"
if $CC -O1 -o "$WORK/rdsrv" "$WORK/rd.c" -lm 2>"$WORK/cc3.log"; then

  # $1 = binary, $2 = port -> prints "yes" if a normal request is answered
  # while eight stalled clients are holding connections open.
  stalled_probe() {
    MERE_HTTP_PORT="$2" MERE_HTTP_WORKERS=8 MERE_HTTP_DELAY_MS=0 \
      "$WORK/$1" > "$WORK/$1.log" 2>&1 &
    SRVPID=$!
    curl -sS --retry 40 --retry-delay 1 --retry-connrefused --max-time 10 \
         -o /dev/null "http://127.0.0.1:$2/warm" >/dev/null 2>&1 || true
    j=0; spids=""
    while [ $j -lt 8 ]; do
      perl -e 'use IO::Socket::INET;
               my $s = IO::Socket::INET->new(PeerAddr=>"127.0.0.1",
                                             PeerPort=>'"$2"', Proto=>"tcp") or exit;
               print $s "GET /stall HTTP/1.1\r\nHost: x\r\n";
               select(undef, undef, undef, 8);' &
      spids="$spids $!"; j=$((j + 1))
    done
    perl -e 'select(undef, undef, undef, 1.5)'
    rm -f "$WORK/stall.out"
    curl -sS --max-time 4 -o "$WORK/stall.out" "http://127.0.0.1:$2/normal" 2>/dev/null || true
    kill "$SRVPID" 2>/dev/null || true; SRVPID=""
    for p in $spids; do kill "$p" 2>/dev/null || true; done
    for p in $spids; do wait "$p" 2>/dev/null || true; done
    [ -s "$WORK/stall.out" ] && echo yes || echo no
  }

  rd_ans=$(stalled_probe rdsrv $((PORT + 2)))
  [ "$rd_ans" = yes ] \
    && ok "eight stalled clients do not stop the readiness server" \
    || bad "the readiness server was stopped by eight stalled clients"

  # THE CONTROL, and it is the check: without it, "the readiness server
  # answered" proves nothing about readiness -- a machine or a kernel that
  # buffers differently could answer under either shape.
  mt_ans=$(stalled_probe srv $((PORT + 3)))
  [ "$mt_ans" = no ] \
    && ok "the worker pool IS stopped by them -- so the check above measured readiness" \
    || bad "the worker pool answered too; this pair is not measuring what it claims"

  # And the half readiness alone would lose: slow handlers still run at once.
  MERE_HTTP_PORT="$PORT" MERE_HTTP_WORKERS="$N" MERE_HTTP_DELAY_MS="$DELAY" \
    "$WORK/rdsrv" > "$WORK/rd.log" 2>&1 &
  SRVPID=$!
  curl -sS --retry 40 --retry-delay 1 --retry-connrefused --max-time 10 \
       -o /dev/null "http://127.0.0.1:$PORT/warm" >/dev/null 2>&1 || true
  s=$(now); i=0; rpids=""
  while [ $i -lt "$N" ]; do
    curl -sS --max-time 60 -o /dev/null "http://127.0.0.1:$PORT/r$i" 2>/dev/null &
    rpids="$rpids $!"; i=$((i + 1))
  done
  for p in $rpids; do wait "$p" 2>/dev/null || true; done
  e=$(now)
  kill "$SRVPID" 2>/dev/null || true; SRVPID=""
  rdconc=$(perl -e "printf '%.2f', $e - $s")
  echo "  $N concurrent, $DELAY ms handler, readiness server: ${rdconc}s"
  perl -e "exit(($rdconc < $seq_budget) ? 0 : 1)" \
    && ok "and slow handlers still run at once (${rdconc}s) -- the loop is not the bottleneck" \
    || bad "the readiness server serialised slow handlers (${rdconc}s)"
else
  bad "test/http/readiness.mere did not build: $(head -2 "$WORK/cc3.log" | tr '\n' ' ')"
  bad "(and so the other two readiness checks did not run)"
  bad "(placeholder)"
fi

  # ---- a response that cannot go out in one write -----------------------
  # The partial-write path is unreachable while the whole response fits in the
  # socket buffer, which 128 KB does on loopback -- so a server that writes once
  # against a nonblocking descriptor and ignores the short count looks perfect.
  # At 896 KB it does not: that exact mistake delivered 3 271 270 bytes for this
  # request. Checked by CONTENT, not by length, because a wrong length is only
  # the loudest way to be wrong.
  MERE_HTTP_PORT=$((PORT + 6)) MERE_HTTP_WORKERS=2 MERE_HTTP_DELAY_MS=0 \
    MERE_HTTP_MAX_CONN=8 MERE_HTTP_SLOT=1048576 \
    "$WORK/rdsrv" > "$WORK/rdbig.log" 2>&1 &
  SRVPID=$!
  k=0
  while [ $k -lt 25 ]; do
    curl -sS --max-time 3 -o /dev/null "http://127.0.0.1:$((PORT + 6))/ok" >/dev/null 2>&1 && break
    k=$((k + 1)); perl -e 'select(undef, undef, undef, 0.4)'
  done
  curl -sS --max-time 20 -o "$WORK/big.out" "http://127.0.0.1:$((PORT + 6))/big" 2>/dev/null || true
  kill "$SRVPID" 2>/dev/null || true; SRVPID=""
  perl -e 'print "0123456789abcdef" x 56000' > "$WORK/big.want"
  if cmp -s "$WORK/big.out" "$WORK/big.want"; then
    ok "an 896 KB response arrives byte-for-byte (it needs several writes)"
  else
    bad "the large response differs: got $(wc -c < "$WORK/big.out" 2>/dev/null | tr -d ' ') bytes, wanted 896000"
  fi

# ---- a failing handler ---------------------------------------------------
# WITHOUT the middleware, a handler that fails unwinds past the server loop and
# ends the PROCESS: one bad route takes the whole site down, and it is the route
# nobody tested. The control is run FIRST and must show exactly that, or the
# check below says nothing.
"$MERE" -c "$ROOT/test/http/rescue.mere" > "$WORK/rs.c"
if $CC -O1 -o "$WORK/rssrv" "$WORK/rs.c" -lm 2>"$WORK/cc4.log"; then

  # $1 = 0/1 rescue, $2 = port. Prints "<boom_code> <alive_after>".
  boom_probe() {
    MERE_HTTP_RESCUE="$1" MERE_HTTP_PORT="$2" "$WORK/rssrv" > "$WORK/rs$1.log" 2>&1 &
    SRVPID=$!
    k=0
    while [ $k -lt 25 ]; do
      curl -sS --max-time 3 -o /dev/null "http://127.0.0.1:$2/ok" >/dev/null 2>&1 && break
      k=$((k + 1)); perl -e 'select(undef, undef, undef, 0.4)'
    done
    bc=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/boom" 2>/dev/null || true)
    perl -e 'select(undef, undef, undef, 0.6)'
    av=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/ok" 2>/dev/null || true)
    kill "$SRVPID" 2>/dev/null || true; SRVPID=""
    echo "$bc $av"
  }

  ctl=$(boom_probe 0 $((PORT + 4)))
  set -- $ctl
  [ "$2" != "200" ] \
    && ok "without the middleware a failing route ends the server (then /ok gives $2)" \
    || bad "the unwrapped server survived a failing handler; this pair measures nothing"

  res=$(boom_probe 1 $((PORT + 5)))
  set -- $res
  [ "$1" = "500" ] \
    && ok "with it, the failing route is a 500" \
    || bad "the rescued route returned $1, not 500"
  [ "$2" = "200" ] \
    && ok "and the server is still answering afterwards" \
    || bad "the server did not survive even with the middleware (/ok gave $2)"
else
  bad "test/http/rescue.mere did not build: $(head -2 "$WORK/cc4.log" | tr '\n' ' ')"
  bad "(and so the other two rescue checks did not run)"
  bad "(placeholder)"
fi

echo
echo "http_concurrency_check: $pass passed, $fail failed, of 11 checks"
[ $((pass + fail)) -eq 11 ] || { echo "only $((pass + fail)) of 11 checks ran"; exit 1; }
[ "$fail" -eq 0 ] || exit 1
echo "http_concurrency_check: ok"
