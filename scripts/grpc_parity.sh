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

cat > "$TMP/hello.proto" <<'PROTO'
syntax = "proto3";
package hello;
message HelloRequest { string name = 1; }
message HelloReply   { string message = 1; }
service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
  // Declared in the schema and NOT handled by the server, so the harness has a
  // real unknown method to call rather than a claim about one.
  rpc NotImplemented (HelloRequest) returns (HelloReply);
}
PROTO
protoc --descriptor_set_out="$TMP/hello.protoset" --include_imports \
  -I"$TMP" "$TMP/hello.proto" || { echo "  FAIL  protoset"; exit 1; }

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

# --- 2. an unknown method ------------------------------------------------
# F1 answers with a named message rather than an RPC status, because the handler
# signature cannot ask for one yet. That is a gap, and a gap is only honest if it
# is CHECKED — the first version of this section printed the gap without calling
# anything, which is a claim, not a check. This calls a method the schema declares
# and the server does not handle, and requires the documented behaviour. When F2
# adds statuses, this fails and says the assertion is stale.
if start_server 1; then
  got=$(grpcurl -plaintext -protoset "$TMP/hello.protoset" -max-time 10 \
          -d '{}' "127.0.0.1:$PORT" hello.Greeter/NotImplemented 2>&1 \
        | python3 -c "import sys,json
d=sys.stdin.read()
try: print(json.loads(d).get('message',''))
except Exception: print('NOT-JSON: ' + d.replace(chr(10),' ')[:110])")
  wait $SRV 2>/dev/null
  case "$got" in
    "no such method: /hello.Greeter/NotImplemented")
      echo "  DOCUMENTED-GAP  unknown method answers a named message, not grpc-status 12" ;;
    *)
      echo "  FAIL  unknown method  expected the documented message, got: [$got]"
      echo "        either the gap closed (retire this section) or routing is wrong."
      fail=1 ;;
  esac
else
  echo "  FAIL  unknown method  the server never started"
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
from h2.events import DataReceived, StreamEnded, SettingsAcknowledged

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
        out = c.data_to_send()
        if out: s.sendall(out)
    return reply_text(body[5:5 + int.from_bytes(body[1:5], "big")]) if body else "NO-BODY"

print(call(1, "first"))
print(call(3, "second"))
# A frame split every seven bytes, so the 9-byte header itself lands across two
# reads and so does the payload.
print(call(5, "split", chunk=7))
# The peer must acknowledge our SETTINGS. Neither client blocks on it, so it is
# asserted rather than assumed — removing the ACK went unnoticed without this.
print("settings-ack" if saw_settings_ack else "NO-SETTINGS-ACK")
s.close()
PY
  wait $SRV 2>/dev/null
  printf 'hello first\nhello second\nhello split\nsettings-ack\n' > "$TMP/h2_want.txt"
  if diff -q "$TMP/h2_want.txt" "$TMP/h2.txt" >/dev/null; then
    echo "  ok    one connection  3 streams (one split across segments) + SETTINGS ack"
  else
    echo "  FAIL  one connection  sequential requests / segment splitting / SETTINGS ack"
    diff "$TMP/h2_want.txt" "$TMP/h2.txt" | sed 's/^/        /' | head -12
    echo "        server log:"; sed 's/^/          /' "$TMP/srv.log" | head -4
    fail=1
  fi
fi

[ "$fail" = 0 ] && echo "grpc_parity: ok" || echo "grpc_parity: FAILED"
[ "$fail" = 0 ]
