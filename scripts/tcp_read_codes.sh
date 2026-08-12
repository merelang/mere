#!/bin/sh
# scripts/tcp_read_codes.sh — a failed read says which failure it was.
#
# `tcp_read` used to return read(2)'s -1 for everything, and with a socket timeout
# set that covers two opposite events: the deadline passed with nothing arriving
# (wait longer) and the connection broke (reconnect). The mraft dogfood told them
# apart by timing the call and asking whether it had failed slowly enough, which
# infers a cause from a duration.
#
#   > 0   bytes read
#     0   the peer closed cleanly — end of stream, not an error
#    -1   nothing arrived before the deadline
#    -2   the connection is gone
#    -3   anything else
#
# The three cases are produced rather than described: a socket nobody writes to, a
# peer that closes cleanly, and a peer that aborts with data still unread in its own
# receive queue (which is what makes close() send RST instead of FIN).
#
# Native only — these are the C backend's sockets. Skips (exit 0) without a C
# compiler.
#
# Usage:
#   sh scripts/tcp_read_codes.sh

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}
PORT=${PORT:-7913}

if ! command -v clang >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
  echo "tcp_read_codes: no C compiler — skipping (this check is optional)"
  exit 0
fi
CC=$(command -v clang || command -v cc)

if [ ! -x "$MERE" ]; then
  echo "tcp_read_codes: $MERE not found — run dune build first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/codes.mere" <<EOF
extern fn tcp_listen: int -> int;
extern fn tcp_accept: int -> int;
extern fn tcp_connect: str -> int -> int;
extern fn tcp_read: int -> int -> int -> int;
extern fn tcp_write: int -> int -> int -> int;
extern fn tcp_close: int -> unit;
extern fn tcp_set_timeout: int -> int -> int;
extern fn mem_alloc: int -> int;
extern fn mem_copy_str: int -> int -> str -> int;

let srv = tcp_listen $PORT;
let buf = mem_alloc 256;

// 1. Nobody writes, and the deadline passes.
let c1 = tcp_connect "127.0.0.1" $PORT;
let a1 = tcp_accept srv;
let _ = tcp_set_timeout a1 150;
let _ = print ("deadline " ++ str_of_int (tcp_read a1 buf 64));
let _ = tcp_close c1;
let _ = tcp_close a1;

// 2. The peer closes cleanly: end of stream, which is 0 and not a failure.
let c2 = tcp_connect "127.0.0.1" $PORT;
let a2 = tcp_accept srv;
let _ = tcp_close c2;
let _ = sleep_ms 50;
let _ = print ("closed " ++ str_of_int (tcp_read a2 buf 64));
let _ = tcp_close a2;

// 3. The peer aborts with data still unread in its receive queue, so its close
//    sends RST rather than FIN.
let c3 = tcp_connect "127.0.0.1" $PORT;
let a3 = tcp_accept srv;
let n = mem_copy_str buf 0 "data the client will never read";
let _ = tcp_write a3 buf n;
let _ = sleep_ms 50;
let _ = tcp_close c3;
let _ = sleep_ms 50;
print ("broken " ++ str_of_int (tcp_read a3 buf 64))
EOF

"$MERE" -c "$TMP/codes.mere" > "$TMP/codes.c"
(cd "$TMP" && "$CC" -O2 -w codes.c -o codes)

got=$("$TMP/codes" | grep -E '^(deadline|closed|broken) ' | tr '\n' ' ')
want="deadline -1 closed 0 broken -2 "

if [ "$got" = "$want" ]; then
  echo "tcp_read_codes: ok  ($(printf '%s' "$got" | sed 's/ $//'))"
  exit 0
fi

echo "tcp_read_codes: FAILED" >&2
echo "  expected: $want" >&2
echo "  got:      $got" >&2
exit 1
