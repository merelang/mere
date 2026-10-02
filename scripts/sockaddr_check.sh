#!/bin/sh
# scripts/sockaddr_check.sh — tcp_listen_at, sock_bind, sock_local_addr /
# sock_peer_addr and fd_last_errno, checked against what the kernel gave the
# probe and the refusals the probe provoked.
#
# WHY THESE ARE A RUNTIME AND NOT AN `extern` A PROGRAM WRITES. bind(2),
# getsockname(2) and getpeername(2) take a `struct sockaddr *`, which no extern
# can spell. So tcp_listen bound INADDR_ANY and nothing could ask which address
# or port a socket had: a ruby on top of this read getsockname from lsof(8).
# The address crosses as text and the family as a name (inet, inet6, unix),
# because AF_INET6 is 30 on macOS and 10 on Linux.
#
# ERRNO IS THE PLATFORM'S NUMBER, and it differs exactly where these calls
# fail: EADDRINUSE is 48 on macOS and 98 on Linux, ECONNRESET 54 and 104,
# ENOTSOCK 38 and 88. The probe prints the number it got; the expected one is
# not written in this file but read from the host's own <errno.h> by a C
# program compiled here, so the transcript is the same claim on every host.
#
# EVERY OTHER EXPECTATION IS SOMETHING THE PROBE WAS GIVEN: the port the
# kernel chose, compared with the port the peer of a connection reports, and
# an RST provoked by closing a socket with an unread byte in it -- after
# poll(2) said the byte had arrived, so the reset is not a race.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "sockaddr_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "sockaddr_check: could not answer, no C compiler" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$MERE" -c "$ROOT/test/sockaddr/sockaddr_probe.mere" > "$TMP/p.c" 2>"$TMP/p.err" \
  || { echo "FAIL sockaddr: mere -c refused the probe"; cat "$TMP/p.err"; exit 1; }
"$CC" -O1 -w -pthread "$TMP/p.c" -o "$TMP/p" 2>"$TMP/cc.err" \
  || { echo "FAIL sockaddr: C compile failed"; cat "$TMP/cc.err"; exit 1; }

# the host's own numbers, as sed substitutions
cat > "$TMP/e.c" <<'C'
#include <errno.h>
#include <stdio.h>
int main(void) {
  printf("s/@EADDRINUSE@/%d/\n", EADDRINUSE);
  printf("s/@EADDRNOTAVAIL@/%d/\n", EADDRNOTAVAIL);
  printf("s/@EINVAL@/%d/\n", EINVAL);
  printf("s/@ENOTCONN@/%d/\n", ENOTCONN);
  printf("s/@ECONNRESET@/%d/\n", ECONNRESET);
  printf("s/@EPIPE@/%d/\n", EPIPE);
  printf("s/@EBADF@/%d/\n", EBADF);
  printf("s/@ENOENT@/%d/\n", ENOENT);
  printf("s/@ENOTSOCK@/%d/\n", ENOTSOCK);
  return 0;
}
C
"$CC" -w "$TMP/e.c" -o "$TMP/e" 2>"$TMP/ecc.err" \
  || { echo "FAIL sockaddr: errno helper did not compile"; cat "$TMP/ecc.err"; exit 1; }
"$TMP/e" > "$TMP/e.sed"

sh "$ROOT/scripts/bounded.sh" 30 "$TMP/p" > "$TMP/got" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL sockaddr: probe exited $rc"; cat "$TMP/got"; exit 1; }

# One line per check, compared AS A WHOLE: a row that stops being printed is a
# failure too, and grep would not see it.
sed -f "$TMP/e.sed" > "$TMP/want" <<'W'
listen 127.0.0.1 ok
errno after success ok
its family ok
its address ok
the kernel chose a port ok
getsockname errno ok
the same port again ok
the same port again errno=@EADDRINUSE@
an address not here ok
an address not here errno=@EADDRNOTAVAIL@
port out of range ok
port out of range errno=@EINVAL@
the wildcard ok
wildcard family matches ok
listen localhost ok
a connect to localhost arrives ok
the peer sees the end ok
listen again through TIME_WAIT ok
connect ok
accept ok
client's peer is the listener's port ok
client's peer address ok
accepted end's local port ok
accepted end's peer is the client ok
the client has an ephemeral port ok
listener's peer ok
listener's peer errno=@ENOTCONN@
client writes ok
the byte arrived ok
read after reset ok
read after reset errno=@ECONNRESET@
write to a pipe with no reader ok
write to a pipe with no reader errno=@EPIPE@
read a closed fd ok
read a closed fd errno=@EBADF@
negative fd ok
negative fd errno=@EBADF@
zero-length read ok
zero-length read errno=@EINVAL@
missing file ok
missing file errno=@ENOENT@
unknown mode ok
unknown mode errno=@EINVAL@
read /dev/null ok
errno after an end of file ok
write a read-only fd ok
write a read-only fd errno=@EBADF@
the other thread's success ok
this thread still errno=@EBADF@
socket ok
an unbound socket's family ok
an unbound socket's port ok
bind 127.0.0.1 ok
bound address ok
bound port ok
bind twice ok
bind twice errno=@EINVAL@
listen ok
connect to the bound socket ok
bind the wildcard ok
an IPv4 socket's wildcard ok
bind an address not here ok
bind an address not here errno=@EADDRNOTAVAIL@
bind the listener's port ok
bind the listener's port errno=@EADDRINUSE@
bind a name ok
a name is not an errno ok
bind a closed fd ok
bind a closed fd errno=@EBADF@
address of a pipe ok
address of a pipe errno=@ENOTSOCK@
address of a closed fd ok
address of a closed fd errno=@EBADF@
socketpair answers two descriptors ok
a pair's end is a unix socket ok
one end writes ok
the other reads it ok
what it read ok
a closed end is the end of file ok
a datagram pair ok
an unknown type ok
an unknown type errno=@EINVAL@
W

n=$(wc -l < "$TMP/want" | tr -d ' ')
if diff -u "$TMP/want" "$TMP/got" > "$TMP/d" 2>&1; then
  echo "sockaddr: $n/$n ok"
else
  echo "FAIL sockaddr: the transcript differs"
  cat "$TMP/d"
  exit 1
fi
