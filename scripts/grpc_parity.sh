#!/bin/sh
# scripts/grpc_parity.sh — serve gRPC from Mere and let real clients check it.
#
# This is the one harness here that does not compare bytes. Every layer underneath
# already has a byte-level gate — protoc for the wire format, hyperframe for the
# frames, hpack for the header compression — and each of those answers "did we
# transcribe this correctly". None of them answers the question a server exists to
# answer, which is whether a client that knows nothing about any of it gets a reply
# it recognises. So this one drives the real thing and reads what comes back.
#
# TWO CLIENTS, because they ask different questions:
#
#   * grpcurl 1.8.8 (Go). One connection per invocation. It is the client the
#     implementation was developed against, so on its own it proves the least.
#   * a python `h2` client. TWO REQUESTS ON ONE CONNECTION, which grpcurl cannot
#     be made to do for a unary method — and which is the case that catches a
#     desynchronised HPACK dynamic table. The second request's headers are encoded
#     against the insertions the first one made; a server that rebuilt its decoder
#     per stream would serve the first request and mis-serve the second.
#
# `-protoset` rather than reflection: grpcurl's first call on a connection is a
# reflection request unless it has the schema locally, and reflection is itself a
# gRPC service. Measured, not assumed.
#
# The server is compiled with the C backend and asked for a BOUNDED number of
# connections, so it exits on its own. A harness that has to kill its subject
# cannot tell a clean exit from a hang.
#
# Skips (exit 0) without protoc, grpcurl, a C compiler, or python h2.
#
# Usage:
#   sh scripts/grpc_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

[ -x "$MERE" ] || { echo "grpc_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
for t in protoc grpcurl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "grpc_parity: $t absent, skipping"; exit 0; }
done
if command -v clang >/dev/null 2>&1; then CC=clang
elif command -v cc >/dev/null 2>&1; then CC=cc
else echo "grpc_parity: no C compiler, skipping"; exit 0; fi
python3 -c "import h2" 2>/dev/null || {
  echo "grpc_parity: python 'h2' is not importable, skipping"; exit 0; }

echo "grpc_parity: clients are $(grpcurl --version 2>&1 | head -1) and python h2 $(python3 -c 'import h2;print(h2.__version__)')"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
set +e

# A free port, asked of the operating system rather than guessed. A hard-coded
# port makes a harness that fails when it is run twice at once.
PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")

# THE SCHEMA IS THE COMMITTED ONE, not a copy pasted into this harness. A copy
# drifts: the example gained streaming methods and a harness holding its own
# `.proto` would have kept calling the old ones and reporting success about a
# schema nobody serves.
protoc --descriptor_set_out="$TMP/hello.protoset" --include_imports \
  -I"$ROOT/examples" "$ROOT/examples/hello.proto" \
  || { echo "  FAIL  protoset"; exit 1; }

# --- build the server ----------------------------------------------------
if ! ( ulimit -t 300; "$MERE" -c "$ROOT/examples/grpc_hello.mere" ) > "$TMP/s.c" 2>"$TMP/emit.err"; then
  echo "  FAIL  build  the server did not compile:"
  sed 's/^/        /' "$TMP/emit.err" | head -6
  echo "grpc_parity: FAILED"; exit 1
fi
if ! ( ulimit -t 300; $CC -O1 -w "$TMP/s.c" -o "$TMP/server" ) 2>"$TMP/cc.err"; then
  echo "  FAIL  build  the generated C did not compile:"
  grep "error:" "$TMP/cc.err" | sed 's/^/        /' | head -6
  echo "grpc_parity: FAILED"; exit 1
fi
echo "  ok    build  the server compiles through the C backend"

# start_server <connections>
#
# THE READINESS CHECK MUST NOT BE A CONNECTION. The first version waited for the
# port by connecting to it — which the server counts, because it serves a bounded
# number of connections and then exits. The probe ate one, the last real call got
# "connection refused", and the harness blamed the server.
#
# Waiting for the server's own "listening" line perturbs nothing. `print` flushes
# (v0.1.221), so the line appears when it is true rather than at exit.
start_server() {
  : > "$TMP/srv.log"
  "$TMP/server" "$PORT" "$1" > "$TMP/srv.log" 2>&1 &
  SRV=$!
  i=0
  while [ "$i" -lt 200 ]; do
    grep -q "listening on" "$TMP/srv.log" 2>/dev/null && return 0
    kill -0 "$SRV" 2>/dev/null || return 1
    i=$((i + 1))
    python3 -c "import time; time.sleep(0.05)"
  done
  return 1
}

# --- 1. grpcurl, one connection per call ---------------------------------
# Four calls, each its own connection, so this also checks that the accept loop
# comes back for the next one.
cat > "$TMP/cases.txt" <<'CASES'
{"name":"mere"}	hello mere
{}	hello 
{"name":"日本語"}	hello 日本語
{"name":"a-very-long-name-that-crosses-no-boundary-but-is-not-short"}	hello a-very-long-name-that-crosses-no-boundary-but-is-not-short
CASES
NCASES=$(grep -c . "$TMP/cases.txt")
if ! start_server "$NCASES"; then
  echo "  FAIL  grpcurl  the server never accepted a connection"
  sed 's/^/        /' "$TMP/srv.log" | head -4
  fail=1
else
  n=0; bad=0
  while IFS="$(printf '\t')" read -r req want; do
    [ -z "$req" ] && continue
    n=$((n + 1))
    got=$(grpcurl -plaintext -protoset "$TMP/hello.protoset" -max-time 10 \
            -d "$req" "127.0.0.1:$PORT" hello.Greeter/SayHello 2>&1 \
          | python3 -c "import sys,json;
d=sys.stdin.read()
try: print(json.loads(d).get('message',''))
except Exception: print('NOT-JSON: ' + d.replace(chr(10),' ')[:100])")
    if [ "$got" != "$want" ]; then
      echo "        request $req"
      echo "          want: [$want]"
      echo "          got : [$got]"
      bad=$((bad + 1))
    fi
  done < "$TMP/cases.txt"
  wait $SRV 2>/dev/null
  if [ "$bad" = 0 ]; then
    echo "  ok    grpcurl  $n calls over $n connections, including an empty request"
  else
    echo "  FAIL  grpcurl  $bad of $n"
    fail=1
  fi
fi

# --- 2. RPC statuses -----------------------------------------------------
#
# A failed call is a status in the TRAILERS, not an HTTP status: the request
# succeeded as HTTP and failed as RPC. Three routes, and they are different code
# paths rather than three spellings of one:
#
#   * a method the schema declares and the server does not handle  -> UNIMPLEMENTED
#   * a method that exists and refuses this input                  -> INVALID_ARGUMENT
#   * a message that has to be percent-encoded on the way out      -> FAILED_PRECONDITION
#
# The third is not decoration. `grpc-message` is percent-encoded by specification
# and grpc-go DECODES it — measured, `caf%C3%A9 %25` came back as `café %` — so a
# raw `%` in a message would be read as the start of an escape.
#
# This section replaced a DOCUMENTED-GAP that asserted the absence of statuses.
# Closing the gap made that assertion fail and say it was stale, which is what it
# was written to do.
cat > "$TMP/status_cases.txt" <<'CASES'
NotImplemented	{}	Unimplemented	no such method: /hello.Greeter/NotImplemented
SayHello	{"name":"boom"}	InvalidArgument	name must not be 'boom'
SayHello	{"name":"unicode"}	FailedPrecondition	café: 100% not ok
CASES
NSTATUS=$(grep -c . "$TMP/status_cases.txt")
if start_server "$NSTATUS"; then
  bad=0
  while IFS="$(printf '\t')" read -r method req wantcode wantmsg; do
    [ -z "$method" ] && continue
    # grpcurl writes a failure to stderr as `Code:` / `Message:` lines. Reduced to
    # one line so a diff names the case rather than a block of formatting.
    got=$(grpcurl -plaintext -protoset "$TMP/hello.protoset" -max-time 10 \
            -d "$req" "127.0.0.1:$PORT" "hello.Greeter/$method" 2>&1 \
          | python3 -c "
import sys, re
t = sys.stdin.read()
c = re.search(r'^\s*Code:\s*(.*)$', t, re.M)
m = re.search(r'^\s*Message:\s*(.*)$', t, re.M)
print((c.group(1).strip() if c else 'NO-CODE') + '|' + (m.group(1).strip() if m else 'NO-MESSAGE'))")
    if [ "$got" != "$wantcode|$wantmsg" ]; then
      echo "        $method $req"
      echo "          want: [$wantcode|$wantmsg]"
      echo "          got : [$got]"
      bad=$((bad + 1))
    fi
  done < "$TMP/status_cases.txt"
  wait $SRV 2>/dev/null
  if [ "$bad" = 0 ]; then
    echo "  ok    statuses  $NSTATUS codes reported, including a percent-encoded message"
  else
    echo "  FAIL  statuses  $bad of $NSTATUS"
    fail=1
  fi
else
  echo "  FAIL  statuses  the server never started"
  fail=1
fi

# --- 3. two requests on ONE connection -----------------------------------
# The case grpcurl cannot express, and the one that catches a per-stream HPACK
# decoder: the second request's header block is encoded against the dynamic-table
# insertions the first one made.
if ! start_server 1; then
  echo "  FAIL  one connection  the server never started"
  fail=1
else
  python3 - "$PORT" > "$TMP/h2.txt" 2>&1 <<'PY'
import socket, sys, time
from h2.connection import H2Connection
from h2.config import H2Configuration
from h2.events import (DataReceived, StreamEnded, SettingsAcknowledged,
                       TrailersReceived, ResponseReceived)

def frame(msg: bytes) -> bytes:
    return b"\x00" + len(msg).to_bytes(4, "big") + msg

def req(name: str) -> bytes:
    b = name.encode()
    return frame(b"\x0a" + bytes([len(b)]) + b) if name else frame(b"")

def reply_text(msg: bytes) -> str:
    # HelloReply { string message = 1 } — field 1, wire type 2
    if not msg: return ""
    assert msg[0] == 0x0a, msg.hex()
    return msg[2:2 + msg[1]].decode()

port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), 10)
c = H2Connection(config=H2Configuration(client_side=True))
c.initiate_connection()
s.sendall(c.data_to_send())

saw_settings_ack = False
last_trailers = {}

def call(sid, name, chunk=0):
    global saw_settings_ack
    hdrs = [(":method", "POST"), (":scheme", "http"), (":authority", f"127.0.0.1:{port}"),
            (":path", "/hello.Greeter/SayHello"),
            ("content-type", "application/grpc"), ("te", "trailers"),
            ("user-agent", "h2-harness/1")]
    c.send_headers(sid, hdrs)
    c.send_data(sid, req(name), end_stream=True)
    out = c.data_to_send()
    if chunk:
        # DELIBERATELY SPLIT ACROSS SEGMENTS. On loopback a request arrives in one
        # read, so a server that parses whatever one read gave it works — and a
        # harness that only ever sends whole frames cannot tell that apart from a
        # server that reassembles. Removing the reassembly step did NOT fail this
        # harness until this existed.
        for i in range(0, len(out), chunk):
            s.sendall(out[i:i + chunk])
            time.sleep(0.004)
    else:
        s.sendall(out)
    body, done = b"", False
    while not done:
        data = s.recv(65535)
        if not data: break
        for ev in c.receive_data(data):
            if isinstance(ev, DataReceived):
                body += ev.data
                c.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
            elif isinstance(ev, StreamEnded):
                done = True
            elif isinstance(ev, SettingsAcknowledged):
                saw_settings_ack = True
            elif isinstance(ev, TrailersReceived):
                # grpcurl only shows the RENDERED code name. The raw trailer is a
                # different observation, and this is the client that can make it.
                last_trailers.clear()
                last_trailers.update({k.decode(): v.decode() for k, v in ev.headers})
        out = c.data_to_send()
        if out: s.sendall(out)
    if not body: return "NO-BODY"        # an error carries no message
    return reply_text(body[5:5 + int.from_bytes(body[1:5], "big")])

print(call(1, "first"))
print(call(3, "second"))
# A frame split every seven bytes, so the 9-byte header itself lands across two
# reads and so does the payload.
print(call(5, "split", chunk=7))
# The peer must acknowledge our SETTINGS. Neither client blocks on it, so it is
# asserted rather than assumed — removing the ACK went unnoticed without this.
print("settings-ack" if saw_settings_ack else "NO-SETTINGS-ACK")
# The error path's raw trailers, straight off the wire. This is the observation
# grpcurl cannot give: it prints the DECODED message and the RENDERED code name, so
# whether the percent-encoding actually happened is invisible there.
#
# The rule is "bytes outside printable ASCII, plus `%` itself" — the same as
# grpc-go's encodeGrpcMessage. So a space and an apostrophe pass through unencoded,
# which is why the first expectation written here was wrong and the wire corrected
# it. "unicode" is the case where the encoding is visible.
call(7, "boom")
print("A grpc-status=" + last_trailers.get("grpc-status", "?")
      + " grpc-message=" + last_trailers.get("grpc-message", "?"))
call(9, "unicode")
print("B grpc-status=" + last_trailers.get("grpc-status", "?")
      + " grpc-message=" + last_trailers.get("grpc-message", "?"))
s.close()
PY
  wait $SRV 2>/dev/null
  { printf 'hello first\nhello second\nhello split\nsettings-ack\n'
    printf 'A grpc-status=3 grpc-message=%s\n' "name must not be 'boom'"
    printf 'B grpc-status=9 grpc-message=%s\n' "caf%C3%A9: 100%25 not ok"
  } > "$TMP/h2_want.txt"
  if diff -q "$TMP/h2_want.txt" "$TMP/h2.txt" >/dev/null; then
    echo "  ok    one connection  5 streams (split / failing / encoded) + SETTINGS ack + raw trailers"
  else
    echo "  FAIL  one connection  sequential requests / segment splitting / SETTINGS ack"
    diff "$TMP/h2_want.txt" "$TMP/h2.txt" | sed 's/^/        /' | head -12
    echo "        server log:"; sed 's/^/          /' "$TMP/srv.log" | head -4
    fail=1
  fi
fi

# --- 5b. the outbound window is actually respected ---------------------
#
# Section 5 does not test this, and poisoning proved it: replacing the window check
# with "the window is a billion bytes" left section 5 GREEN. The reason is not a
# missing case, it is the shape of the client. A client that acknowledges data as
# it reads has already granted more credit by the time the next chunk is processed,
# so a server that ignores the window never overruns anything it can notice. THE
# WELL-BEHAVED CLIENT IS THE ONE THAT CANNOT SEE THIS BUG.
#
# So this section uses a deliberately rude client: it advertises a window of 8192,
# asks for 200000 bytes, and then STOPS READING at the h2 level — draining the
# socket raw, without acknowledging anything. The measurement is how many bytes
# arrive before the first WINDOW_UPDATE is sent, which is a number the protocol
# fixes: at most the window.
#
# 8192 rather than the default 65535 for two reasons. It is far below any kernel
# socket buffer, so "the server stopped" and "the kernel stopped it" cannot be
# confused. And it is the only case in this harness where
# SETTINGS_INITIAL_WINDOW_SIZE differs from the default, so it is the only one that
# exercises the delta-adjustment in `apply_settings` at all — with 65535 that
# arithmetic is a no-op and a wrong sign would pass.
if start_server 1; then
  python3 - "$PORT" > "$TMP/win.txt" 2>&1 <<'PY'
import socket, sys
from h2.connection import H2Connection
from h2.config import H2Configuration
from h2.events import DataReceived, StreamEnded
from h2.settings import SettingCodes

WINDOW = 8192
WANT = 200000
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), 20)
c = H2Connection(config=H2Configuration(client_side=True))
c.initiate_connection()
# `update_settings` and NOT `local_settings.initial_window_size = ...`, which was
# the first version here and is silently ignored: h2 emitted its opening SETTINGS
# with the default 65535 anyway, the server correctly sent 65535 bytes, and the
# harness blamed the server. Measured by dumping what the client actually put on
# the wire.
#
# It also makes this a SECOND SETTINGS frame, arriving after the connection is up —
# so the window here is reached by the delta path in `apply_settings`, which no
# other case in this harness exercises with a value that changes anything.
c.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: WINDOW})
s.sendall(c.data_to_send())
c.send_headers(1, [(":method", "POST"), (":scheme", "http"),
                   (":authority", f"127.0.0.1:{port}"),
                   (":path", "/hello.Greeter/Fill"),
                   ("content-type", "application/grpc"), ("te", "trailers")])
body = b"\x0a" + bytes([len(str(WANT))]) + str(WANT).encode()
c.send_data(1, b"\x00" + len(body).to_bytes(4, "big") + body, end_stream=True)
s.sendall(c.data_to_send())

# Drain the socket WITHOUT telling h2 anything, so no WINDOW_UPDATE can go out.
raw = b""
s.settimeout(1.0)
while len(raw) < WANT:
    try:
        d = s.recv(65535)
    except socket.timeout:
        break                       # the server stopped talking: it is waiting
    if not d:
        break
    raw += d

# The stream window bounds the DATA payload. `raw` also carries the response
# HEADERS frame and frame headers, so allow generous slack and still be nowhere
# near 200000 — the poisoned server sends everything it has.
print("stopped-within-window" if len(raw) < WINDOW * 3
      else f"OVERRAN window={WINDOW} raw={len(raw)}")

# Now let it finish, so a server that merely died is not mistaken for one that
# waited politely. Everything read so far goes into h2 first.
got, done = b"", False
for ev in c.receive_data(raw):
    if isinstance(ev, DataReceived):
        got += ev.data
        c.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
    elif isinstance(ev, StreamEnded):
        done = True
o = c.data_to_send()
if o: s.sendall(o)
s.settimeout(30)
while not done:
    d = s.recv(65535)
    if not d: break
    for ev in c.receive_data(d):
        if isinstance(ev, DataReceived):
            got += ev.data
            c.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
        elif isinstance(ev, StreamEnded):
            done = True
    o = c.data_to_send()
    if o: s.sendall(o)
ln = int.from_bytes(got[1:5], "big")
msg = got[5:5 + ln]
j, shift, n = 1, 0, 0
while True:
    b = msg[j]; n |= (b & 0x7f) << shift; j += 1; shift += 7
    if not b & 0x80: break
print("resumed-and-complete" if msg[j:j + n] == b"x" * WANT
      else f"WRONG-AFTER-RESUME len={n}")
s.close()
PY
  wait $SRV 2>/dev/null
  printf 'stopped-within-window\nresumed-and-complete\n' > "$TMP/win_want.txt"
  if diff -q "$TMP/win_want.txt" "$TMP/win.txt" >/dev/null; then
    echo "  ok    outbound window  stopped at an 8192-byte window, resumed on WINDOW_UPDATE"
  else
    echo "  FAIL  outbound window"
    diff "$TMP/win_want.txt" "$TMP/win.txt" | sed 's/^/        /' | head -8
    echo "        server log:"; sed 's/^/          /' "$TMP/srv.log" | head -4
    fail=1
  fi
else
  echo "  FAIL  outbound window  the server never started"
  fail=1
fi

# --- 5c. SETTINGS ADJUSTS a spent window, it does not reset it ---------
#
# RFC 9113 6.9.2: a SETTINGS_INITIAL_WINDOW_SIZE arriving mid-connection changes an
# open stream's window BY THE DELTA. A stream that has spent 65535 of a 65535
# window has 0 left, and a new size of 8192 must leave it at -57343 — NEGATIVE,
# which is legal and is the only way to get there.
#
# Section 5b cannot see the difference and poisoning proved it: replacing the delta
# with `swin = v` left 5b green. The reason is arithmetic, not coverage — when the
# SETTINGS arrives before the stream has spent anything, `65535 + (8192 - 65535)`
# and `8192` are the same number. THE TWO RULES ONLY DISAGREE AFTER CREDIT HAS BEEN
# SPENT, so the SETTINGS has to arrive in the middle of a response.
#
# The frames here are hand-built and the replies parsed by hand, because h2 keeps
# its own flow-control accounting and would refuse to send a WINDOW_UPDATE for
# credit it does not believe it owes. h2 still builds the REQUEST, because that
# needs HPACK.
#
# The discriminator is step 4: with the connection window refilled and the stream
# window driven negative, a correct server sends NOTHING. A server that reset the
# window to 8192 sends 8192 bytes it was never granted.
if start_server 1; then
  python3 - "$PORT" > "$TMP/delta.txt" 2>&1 <<'PY'
import socket, sys
from h2.connection import H2Connection
from h2.config import H2Configuration

WANT = 200000
port = int(sys.argv[1])

def frame(ty, flags, stream, payload=b""):
    return (len(payload).to_bytes(3, "big") + bytes([ty, flags])
            + (stream & 0x7fffffff).to_bytes(4, "big") + payload)

def window_update(stream, inc):
    return frame(8, 0, stream, inc.to_bytes(4, "big"))

def settings(pairs):
    body = b"".join(k.to_bytes(2, "big") + v.to_bytes(4, "big") for k, v in pairs)
    return frame(4, 0, 0, body)

def drain(sock, seconds=1.0):
    """Read until the peer goes quiet. Returns the raw bytes."""
    sock.settimeout(seconds)
    out = b""
    while True:
        try:
            d = sock.recv(65535)
        except socket.timeout:
            return out
        if not d:
            return out
        out += d

def data_bytes(raw, carry=b""):
    """Total DATA payload in `raw`, plus whatever tail did not form a whole frame."""
    buf = carry + raw
    total, i = 0, 0
    while i + 9 <= len(buf):
        ln = int.from_bytes(buf[i:i + 3], "big")
        if i + 9 + ln > len(buf):
            break
        if buf[i + 3] == 0:
            total += ln
        i += 9 + ln
    return total, buf[i:]

s = socket.create_connection(("127.0.0.1", port), 20)
c = H2Connection(config=H2Configuration(client_side=True))
c.initiate_connection()
c.send_headers(1, [(":method", "POST"), (":scheme", "http"),
                   (":authority", f"127.0.0.1:{port}"),
                   (":path", "/hello.Greeter/Fill"),
                   ("content-type", "application/grpc"), ("te", "trailers")])
body = b"\x0a" + bytes([len(str(WANT))]) + str(WANT).encode()
c.send_data(1, b"\x00" + len(body).to_bytes(4, "big") + body, end_stream=True)
s.sendall(c.data_to_send())

# 1-2. Let it run out of window. Both windows start at 65535, so it stops there.
got1, carry = data_bytes(drain(s))
print("phase1 " + ("spent-the-window" if 60000 < got1 <= 65535
                   else f"UNEXPECTED got={got1}"))

# 3. Refill the CONNECTION window only. The stream window stays at 0.
s.sendall(window_update(0, 200000))

# 4. Now shrink the initial window. Delta: 0 + (8192 - 65535) = -57343.
s.sendall(settings([(4, 8192)]))
got2, carry = data_bytes(drain(s), carry)
print("phase2 " + ("stayed-blocked" if got2 == 0
                   else f"SENT {got2} BYTES IT WAS NOT GRANTED"))

# 5. RAISE the initial window, but not by enough. Delta: -57343 + (60000 - 8192)
# = -5535, still negative, so still nothing. A server that reset would now think it
# had 60000 bytes of credit.
s.sendall(settings([(4, 60000)]))
got3, carry = data_bytes(drain(s), carry)
print("phase3 " + ("still-blocked" if got3 == 0 else f"SENT {got3} TOO EARLY"))

# 6. Raise it enough: -5535 + (300000 - 60000) = 234465, against 134474 still to
# send. THE STREAM REOPENS ON A SETTINGS ALONE, with no WINDOW_UPDATE for it at any
# point in this connection.
#
# 300000 and not 200000, which was the first number here and left the server nine
# bytes short: the delta granted exactly 134465 and the wire total is 200009, not
# 200000. The gRPC prefix and the protobuf tag are not in the field length — the
# same slip as the frame-count expectation in section 5.
#
# That is a conforming way for a peer to reopen a stalled stream, and this server
# did not support it: the SETTINGS branch of `await_window` recursed — waiting for a
# WINDOW_UPDATE that a peer is under no obligation to send — under a comment
# claiming it returned to its caller. Nothing here noticed until a poison in a
# DIFFERENT rule turned out to be undetectable for the same reason.
s.sendall(settings([(4, 300000)]))
got4, _ = data_bytes(drain(s, 3.0), carry)
total = got1 + got2 + got3 + got4
# 5 bytes of gRPC prefix + protobuf tag + a 3-byte varint + the field.
expect = 5 + 1 + 3 + WANT
print("phase4 " + ("reopened-by-settings-alone" if total == expect
                   else f"WRONG total={total} expected={expect}"))
s.close()
PY
  wait $SRV 2>/dev/null
  { printf 'phase1 spent-the-window\nphase2 stayed-blocked\n'
    printf 'phase3 still-blocked\nphase4 reopened-by-settings-alone\n'
  } > "$TMP/delta_want.txt"
  if diff -q "$TMP/delta_want.txt" "$TMP/delta.txt" >/dev/null; then
    echo "  ok    window delta  SETTINGS adjusts a spent window, and can reopen it alone"
  else
    echo "  FAIL  window delta"
    diff "$TMP/delta_want.txt" "$TMP/delta.txt" | sed 's/^/        /' | head -8
    echo "        server log:"; sed 's/^/          /' "$TMP/srv.log" | head -4
    fail=1
  fi
else
  echo "  FAIL  window delta  the server never started"
  fail=1
fi

# --- 5d. an illegal frame is refused ------------------------------------
#
# A WINDOW_UPDATE with an increment of 0 is a PROTOCOL ERROR (RFC 9113 6.9). No
# conforming client sends one, so this guard is unreachable from every other case
# here — and a guard nothing reaches is indistinguishable from a wrong one. It is
# hand-built because h2 will not construct an illegal frame.
#
# The first version of this ran inside section 5c on a second socket. THIS SERVER
# SERVES ONE CONNECTION AT A TIME, so that socket sat in the listen backlog and the
# silence read as "the frame was accepted" — a harness measuring its own queueing.
# It gets its own connection now.
#
# What it caught: the rule was written twice. The frame loop IGNORED a zero
# increment and the window-wait loop FAILED on it, and the ignoring one was on the
# path every ordinary frame takes.
if start_server 1; then
  python3 - "$PORT" > "$TMP/illegal.txt" 2>&1 <<'PY'
import socket, sys
from h2.connection import H2Connection
from h2.config import H2Configuration

port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), 20)
c = H2Connection(config=H2Configuration(client_side=True))
c.initiate_connection()
s.sendall(c.data_to_send())
# 9-byte header, type 8, stream 0, a four-byte increment of zero.
s.sendall((4).to_bytes(3, "big") + bytes([8, 0]) + (0).to_bytes(4, "big")
          + (0).to_bytes(4, "big"))
s.settimeout(3.0)
closed = False
try:
    while True:
        d = s.recv(65535)          # the server's own SETTINGS arrives first
        if d == b"":
            closed = True
            break
except socket.timeout:
    closed = False                 # still talking: the illegal frame was accepted
except ConnectionResetError:
    closed = True
print("zero-increment " + ("refused" if closed else "ACCEPTED"))
s.close()
PY
  wait $SRV 2>/dev/null
  printf 'zero-increment refused\n' > "$TMP/illegal_want.txt"
  if diff -q "$TMP/illegal_want.txt" "$TMP/illegal.txt" >/dev/null; then
    echo "  ok    illegal frame  a WINDOW_UPDATE increment of 0 is refused"
  else
    echo "  FAIL  illegal frame"
    diff "$TMP/illegal_want.txt" "$TMP/illegal.txt" | sed 's/^/        /' | head -6
    echo "        server log:"; sed 's/^/          /' "$TMP/srv.log" | head -3
    fail=1
  fi
else
  echo "  FAIL  illegal frame  the server never started"
  fail=1
fi

# --- 4. streaming, through grpcurl -------------------------------------
#
# The three shapes a gRPC method can have beyond unary, driven by the client that
# knows the schema. grpcurl reads a client-streaming request as a sequence of JSON
# objects on stdin (`-d @`), which is the only way to send more than one message
# without writing the framing by hand.
#
# What makes these worth separate cases rather than one: they are three DIFFERENT
# things about the same list. Server-streaming says the reply can hold many
# messages; client-streaming says the request does; Echo says the two counts are
# independent. A single bidi case would pass with any of the three broken.
#
# NOT TESTED HERE, and stated because a reader will look for it: INTERLEAVING. The
# handler runs after the request half-closes, so no reply can precede the last
# request message. Every case below sends everything, then reads.
cat > "$TMP/stream_cases.txt" <<'CASES'
SayHelloStream	{"name":"mere"}	hello mere #1|hello mere #2|hello mere #3
SayHelloMany	{"name":"a"}{"name":"b"}{"name":"c"}	hello a, b, c
SayHelloMany	{"name":"solo"}	hello solo
Echo	{"name":"x"}{"name":"y"}	echo x|echo y
Echo	{"name":"one"}	echo one
CASES
NSTREAM=$(grep -c . "$TMP/stream_cases.txt")
if start_server "$NSTREAM"; then
  bad=0
  while IFS="$(printf '\t')" read -r method req want; do
    [ -z "$method" ] && continue
    # Every reply message's `message` field, joined with `|`. Joining rather than
    # counting means a reordering or a dropped message shows up as content.
    got=$(printf '%s' "$req" | grpcurl -plaintext -protoset "$TMP/hello.protoset" \
            -max-time 20 -d @ "127.0.0.1:$PORT" "hello.Greeter/$method" 2>&1 \
          | python3 -c "
import sys, json
t = sys.stdin.read()
# grpcurl prints one JSON object per reply message, concatenated.
d = json.JSONDecoder(); out = []; i = 0
try:
    while i < len(t):
        while i < len(t) and t[i] in ' \n\r\t': i += 1
        if i >= len(t): break
        o, i = d.raw_decode(t, i)
        out.append(o.get('message', ''))
    print('|'.join(out))
except Exception:
    print('NOT-JSON: ' + t.replace(chr(10), ' ')[:120])")
    if [ "$got" != "$want" ]; then
      echo "        $method  <- $req"
      echo "          want: [$want]"
      echo "          got : [$got]"
      bad=$((bad + 1))
    fi
  done < "$TMP/stream_cases.txt"
  wait $SRV 2>/dev/null
  if [ "$bad" = 0 ]; then
    echo "  ok    streaming  $NSTREAM calls: server-streaming, client-streaming, bidi"
  else
    echo "  FAIL  streaming  $bad of $NSTREAM"
    sed 's/^/        /' "$TMP/srv.log" | head -3
    fail=1
  fi
else
  echo "  FAIL  streaming  the server never started"
  fail=1
fi

# --- 5. flow control, in both directions -------------------------------
#
# Four numbers, each measured against this client before any of the code existed:
#
#   * a DATA frame may not exceed SETTINGS_MAX_FRAME_SIZE, 16384 by default. At
#     16385 the client refuses the frame outright (`FrameTooLargeError`) — so this
#     bites BEFORE any window does, and a "flow control" fix that did not also
#     split frames would still fail here.
#   * the flow-control window is 65535, per connection and per stream. At 65536 the
#     peer stops accepting DATA until it sends WINDOW_UPDATE.
#   * inbound, that same window is OURS TO REFILL: a 70009-byte request stalled at
#     exactly 65535 with no WINDOW_UPDATE from the server.
#   * `wbuf` holds 16384 bytes and nothing checked it, so a larger response wrote
#     past the buffer and RETURNED SUCCESS. That one is unobservable from here,
#     which is why `send` fails loudly instead.
#
# `Fill` and `Measure` keep the two directions apart. A method that answered a
# large request with a large reply would pass while only one direction worked,
# because from a client both failures look identical: nothing arrives.
#
# The sizes straddle each boundary rather than clearing it comfortably. 16384 and
# 16385 differ by the one byte that decides whether a response needs two frames.
if start_server 1; then
  python3 - "$PORT" > "$TMP/flow.txt" 2>&1 <<'PY'
import socket, sys
from h2.connection import H2Connection
from h2.config import H2Configuration
from h2.events import DataReceived, StreamEnded, TrailersReceived
from h2.settings import SettingCodes

port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), 20); s.settimeout(30)
c = H2Connection(config=H2Configuration(client_side=True))
c.initiate_connection(); s.sendall(c.data_to_send())

def varint(n):
    out = b""
    while True:
        x = n & 0x7f; n >>= 7
        out += bytes([x | 0x80]) if n else bytes([x])
        if not n: return out

def req_msg(name: bytes) -> bytes:
    body = b"\x0a" + varint(len(name)) + name if name else b""
    return b"\x00" + len(body).to_bytes(4, "big") + body

def reply_names(body: bytes):
    """Split a gRPC response body into messages and return each `message` field."""
    out, i = [], 0
    while i + 5 <= len(body):
        ln = int.from_bytes(body[i + 1:i + 5], "big")
        msg = body[i + 5:i + 5 + ln]
        if msg:
            assert msg[0] == 0x0a, msg[:8].hex()
            # a varint length follows the tag
            j, shift, n = 1, 0, 0
            while True:
                b = msg[j]; n |= (b & 0x7f) << shift; j += 1; shift += 7
                if not b & 0x80: break
            out.append(msg[j:j + n])
        else:
            out.append(b"")
        i += 5 + ln
    return out

sid = [1]
MAXSEEN = [0]
def call(method, names, track_max=False):
    """Send every message, then read the whole reply. Returns (replies, data_frames)."""
    i = sid[0]; sid[0] += 2
    c.send_headers(i, [(":method", "POST"), (":scheme", "http"),
                       (":authority", f"127.0.0.1:{port}"),
                       (":path", f"/hello.Greeter/{method}"),
                       ("content-type", "application/grpc"), ("te", "trailers")])
    s.sendall(c.data_to_send())
    payload = b"".join(req_msg(n) for n in names)
    sent = 0
    while sent < len(payload) or sent == 0:
        w = c.local_flow_control_window(i)
        if w <= 0:
            # OUR window into the server is exhausted; it must send WINDOW_UPDATE.
            d = s.recv(65535)
            if not d: return ("STALL-EOF", 0)
            for _ in c.receive_data(d): pass
            o = c.data_to_send()
            if o: s.sendall(o)
            continue
        n = min(w, c.max_outbound_frame_size, len(payload) - sent)
        c.send_data(i, payload[sent:sent + n], end_stream=(sent + n == len(payload)))
        sent += n
        o = c.data_to_send()
        if o: s.sendall(o)
        if sent >= len(payload): break
    body, frames, done = b"", 0, False
    while not done:
        d = s.recv(65535)
        if not d: break
        for ev in c.receive_data(d):
            if isinstance(ev, DataReceived):
                body += ev.data; frames += 1
                if track_max:
                    MAXSEEN[0] = max(MAXSEEN[0], len(ev.data))
                c.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
            elif isinstance(ev, StreamEnded):
                done = True
        o = c.data_to_send()
        if o: s.sendall(o)
    return (reply_names(body), frames)

# OUTBOUND, straddling both boundaries.
#
# THE BOUNDARY IN THE FIELD IS NOT THE BOUNDARY ON THE WIRE, and the first version
# of this section had the expectation wrong because of it. A `Fill 16384` reply
# carries 16384 bytes in a string field, but on the wire that is 5 bytes of gRPC
# prefix plus a protobuf tag plus a 3-byte varint plus the field — 16393 — so it
# needs TWO frames already. 16000 is the largest round size here that fits one.
for size in (16000, 16384, 16385, 65535, 65536, 200000):
    reps, frames = call("Fill", [str(size).encode()])
    if reps == "STALL-EOF":
        print(f"Fill {size}: STALL"); continue
    ok = len(reps) == 1 and len(reps[0]) == size and reps[0] == b"x" * size
    print(f"Fill {size}: {'ok' if ok else 'WRONG len=' + str(len(reps[0]) if reps else -1)}"
          f" frames={'1' if frames == 1 else 'many'}")

# INBOUND. The reply is tiny, so only the request direction can fail here.
for size in (65535, 65536, 300000):
    reps, _ = call("Measure", [b"y" * size])
    got = reps[0].decode() if reps and reps != "STALL-EOF" else "STALL"
    print(f"Measure {size}: {'ok' if got == str(size) else 'WRONG ' + got}")

# SETTINGS_MAX_FRAME_SIZE IS HONOURED WHEN IT IS RAISED.
#
# This cannot be a conformance check. The setting's minimum IS the default 16384, so
# a peer can only ever raise it — a server that ignores it sends smaller frames than
# it could, which is legal. Poisoning the server to ignore MAX_FRAME_SIZE therefore
# left every other case green, and it should have.
#
# So the claim being checked is behavioural: told it may send 32768-byte frames, the
# server does. Without this, honouring the setting is code with no observer.
c.update_settings({SettingCodes.MAX_FRAME_SIZE: 32768})
s.sendall(c.data_to_send())
reps, frames = call("Fill", [b"100000"], track_max=True)
print(f"MAX_FRAME_SIZE 32768: {'used' if MAXSEEN[0] > 16384 else 'IGNORED max=' + str(MAXSEEN[0])}")

# MESSAGE BOUNDARIES SURVIVE FRAME BOUNDARIES. Two 40000-byte Echo messages: each
# reply is larger than one frame, and there are two of them — so a reader that
# treated a DATA payload as a message, or a writer that let two messages share a
# frame boundary wrongly, gets a different answer than a reader that follows the
# gRPC length prefixes.
reps, frames = call("Echo", [b"p" * 40000, b"q" * 40000])
ok = (len(reps) == 2 and reps[0] == b"echo " + b"p" * 40000
      and reps[1] == b"echo " + b"q" * 40000)
print(f"Echo 2x40000: {'ok' if ok else 'WRONG ' + str([len(r) for r in reps])}"
      f" (spread over {'several' if frames > 2 else 'too few'} DATA frames)")
s.close()
PY
  wait $SRV 2>/dev/null
  { printf 'Fill 16000: ok frames=1\n'
    printf 'Fill 16384: ok frames=many\n'
    printf 'Fill 16385: ok frames=many\n'
    printf 'Fill 65535: ok frames=many\n'
    printf 'Fill 65536: ok frames=many\n'
    printf 'Fill 200000: ok frames=many\n'
    printf 'Measure 65535: ok\nMeasure 65536: ok\nMeasure 300000: ok\n'
    printf 'MAX_FRAME_SIZE 32768: used\n'
    printf 'Echo 2x40000: ok (spread over several DATA frames)\n'
  } > "$TMP/flow_want.txt"
  if diff -q "$TMP/flow_want.txt" "$TMP/flow.txt" >/dev/null; then
    echo "  ok    flow control  10 cases: both directions, both boundaries, MAX_FRAME_SIZE"
  else
    echo "  FAIL  flow control"
    diff "$TMP/flow_want.txt" "$TMP/flow.txt" | sed 's/^/        /' | head -14
    echo "        server log:"; sed 's/^/          /' "$TMP/srv.log" | head -4
    fail=1
  fi
else
  echo "  FAIL  flow control  the server never started"
  fail=1
fi

[ "$fail" = 0 ] && echo "grpc_parity: ok" || echo "grpc_parity: FAILED"
[ "$fail" = 0 ]
