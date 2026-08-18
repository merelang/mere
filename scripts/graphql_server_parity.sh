#!/bin/sh
# scripts/graphql_server_parity.sh — the GraphQL endpoint, driven by real clients.
#
# WHAT THIS GATE IS FOR, and what it deliberately leaves to others. Execution is checked
# exhaustively by `graphql_exec_parity.sh` against graphql-js, introspection by
# `graphql_intro_parity.sh`, validation by `graphql_validate_parity.sh` — none of which
# involve a socket. What is new here is the TRANSPORT, so that is what this checks:
# request framing, `Content-Length`, header case, the error statuses, and that a client
# which knows nothing about any of it gets JSON it can parse.
#
# The answers are pinned as literals against the fixture data in the example, and the
# ORACLE for each one is graphql-js executing the same query against the same three
# people — so a wrong answer is caught even though the resolvers are hand-written on both
# sides. That is the honest limit of an oracle here: `user`/`users` return real data, and
# real data has to be written twice or generated. It is written twice and compared.
#
# TWO RUDE CLIENTS, because curl is polite in exactly the ways that hide bugs:
#   * a request whose headers and body arrive in SEPARATE writes — on loopback curl sends
#     one packet, so a server that parses whatever one read gave it works
#   * a lowercase `content-length`, which HTTP allows and curl does not send
#
# Skips (exit 0) without a C compiler, curl, or graphql-js.
#
# Usage:
#   sh scripts/graphql_server_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

[ -x "$MERE" ] || { echo "graphql_server_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
for t in curl python3 node; do
  command -v "$t" >/dev/null 2>&1 || { echo "graphql_server_parity: $t absent, skipping"; exit 0; }
done
if command -v clang >/dev/null 2>&1; then CC=clang
elif command -v cc >/dev/null 2>&1; then CC=cc
else echo "graphql_server_parity: no C compiler, skipping"; exit 0; fi
GQL_DIR=""
for cand in "$ROOT/node_modules/graphql" "$(npm root -g 2>/dev/null)/graphql"; do
  [ -f "$cand/package.json" ] && { GQL_DIR=$cand; break; }
done
[ -n "$GQL_DIR" ] || { echo "graphql_server_parity: graphql-js not found, skipping"; exit 0; }
echo "graphql_server_parity: clients are $(curl --version | head -1 | cut -d' ' -f1-2) and python3; oracle is graphql-js $(node -p "require('$GQL_DIR/package.json').version")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
set +e

# --- build, natively ------------------------------------------------------
#
# The C backend, not Wasm: this is a binary you can hand somebody, the same as
# examples/grpc_hello.mere. It is also the half of the story that was impossible until
# recently — every gate for contrib/graphql runs the interpreter, and the interpreter
# cannot listen on a socket.
if ! ( ulimit -t 300; "$MERE" -c "$ROOT/examples/graphql_server.mere" ) > "$TMP/s.c" 2>"$TMP/emit.err"; then
  echo "  FAIL  build  the server did not compile to C:"
  sed 's/^/        /' "$TMP/emit.err" | head -6
  echo "graphql_server_parity: FAILED"; exit 1
fi
if ! ( ulimit -t 300; $CC -O1 -w "$TMP/s.c" -o "$TMP/server" ) 2>"$TMP/cc.err"; then
  echo "  FAIL  build  the generated C did not compile:"
  grep "error:" "$TMP/cc.err" | sed 's/^/        /' | head -6
  echo "graphql_server_parity: FAILED"; exit 1
fi
echo "  ok    build  the whole GraphQL stack compiles and links natively"

PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")

# THE READINESS CHECK MUST NOT BE A CONNECTION: the server answers a bounded number of
# requests and then exits, so a probe that connects eats one. Waiting for its own
# "listening" line perturbs nothing.
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

# A BOUNDED WAIT, because `wait` on a server that is stuck never returns and a harness
# that hangs is worse than one that fails: it reports nothing at all, and it does so
# after consuming the whole budget of whatever is running it.
#
# Found by poisoning. A server that stopped reading past the first packet left the split
# request unanswered, this script blocked in `wait`, and the poison run had to be killed
# from outside — so the poison that proved the case was load-bearing also proved the
# harness was not safe to run it.
wait_server() {
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$SRV" 2>/dev/null || { wait "$SRV" 2>/dev/null; return 0; }
    i=$((i + 1))
    python3 -c "import time; time.sleep(0.1)"
  done
  echo "        the server did not exit after answering; killing it"
  kill -9 "$SRV" 2>/dev/null
  wait "$SRV" 2>/dev/null
  return 1
}

# --- the corpus, and the oracle's answers --------------------------------
#
# The fixture is the three people in the example. It is written here too, and that
# duplication is the price of resolvers that return real data — the alternative is an
# oracle that only agrees with itself.
cat > "$TMP/queries.txt" <<'Q'
{ hello }
{ user(id: 2) { name email } }
{ user(id: 1) { id name } }
{ user(id: 99) { name } }
{ users { id name } }
{ users(first: 2) { name } }
{ users(first: 0) { name } }
{ user(id: 2) { name } users(first: 1) { name } }
{ user(id: 4) { name email } }
{ users { name } }
Q
cat > "$TMP/vars.txt" <<'Q'
query Q($n: Int!) { user(id: $n) { name } }	{"n":3}
query Q($n: Int!) { user(id: $n) { name } }	{"n":1}
query Q($k: Int) { users(first: $k) { name } }	{"k":1}
Q

node --input-type=module > "$TMP/want.txt" 2>"$TMP/oracle.err" <<NODE
import * as g from "$GQL_DIR/index.js";
import { readFileSync } from "fs";
const sdl = \`type Query {
  hello: String
  user(id: Int!): User
  users(first: Int = 10): [User!]!
}
type User { id: Int! name: String! email: String }\`;
// The fourth row is a non-ASCII name, and what it turned out to check is not what it
// was added for. It went in to catch a `Content-Length` measured in characters — and it
// did not, because MERE'S `str_len` ALREADY COUNTS BYTES (`str_len "だいち"` is 9). The
// poison and the correct code were the same program, so no corpus could tell them apart.
// The row stays because it does check something real: that a multi-byte body survives
// the whole path — read, parse, execute, serialise, frame — unchanged.
const people = [{id:1,name:"alice",email:"alice@example.com"},
                {id:2,name:"bob",email:"bob@example.com"},
                {id:3,name:"carol",email:"carol@example.com"},
                {id:4,name:"だいち",email:"daichi@example.com"}];
const root = {
  hello: () => "hello from Mere",
  user: ({id}) => people.find(p => p.id === id) ?? null,
  users: ({first}) => people.slice(0, first),
};
const schema = g.buildSchema(sdl);
const out = [];
const run = (q, vars) => {
  const r = g.executeSync({schema, document: g.parse(q), rootValue: root,
                           variableValues: vars});
  out.push(r.errors ? "ORACLE-ERROR " + r.errors.map(e => e.message).join("; ")
                    : JSON.stringify({data: r.data}));
};
for (const q of readFileSync("$TMP/queries.txt","utf8").split("\n").filter(l=>l.trim()))
  run(q, {});
for (const l of readFileSync("$TMP/vars.txt","utf8").split("\n").filter(l=>l.trim())) {
  const [q, v] = l.split("\t");
  run(q, JSON.parse(v));
}
console.log(out.join("\n"));
NODE
if [ ! -s "$TMP/want.txt" ]; then
  echo "  FAIL  oracle  graphql-js could not answer:"
  sed 's/^/        /' "$TMP/oracle.err" | head -6
  echo "graphql_server_parity: FAILED"; exit 1
fi
if grep -q "^ORACLE-ERROR" "$TMP/want.txt"; then
  echo "  FAIL  corpus  the ORACLE rejected a query this harness wrote:"
  grep -n "^ORACLE-ERROR" "$TMP/want.txt" | head -4 | sed 's/^/        /'
  echo "graphql_server_parity: FAILED"; exit 1
fi
NQ=$(grep -c . "$TMP/queries.txt")
NV=$(grep -c . "$TMP/vars.txt")
NTOTAL=$((NQ + NV))

# --- 1. the endpoint answers what graphql-js answers ---------------------
if ! start_server "$NTOTAL"; then
  echo "  FAIL  endpoint  the server never started"
  sed 's/^/        /' "$TMP/srv.log" | head -4
  fail=1
else
  : > "$TMP/got.txt"
  while IFS= read -r q; do
    [ -z "$q" ] && continue
    printf '%s' "$q" | python3 -c '
import sys, json
print(json.dumps({"query": sys.stdin.read()}))' > "$TMP/body.json"
    curl -sS --max-time 8 -X POST --data-binary @"$TMP/body.json" \
      "http://127.0.0.1:$PORT/graphql" >> "$TMP/got.txt"
    echo >> "$TMP/got.txt"
  done < "$TMP/queries.txt"
  while IFS="$(printf '\t')" read -r q v; do
    [ -z "$q" ] && continue
    python3 -c '
import sys, json
q, v = sys.argv[1], sys.argv[2]
print(json.dumps({"query": q, "variables": json.loads(v)}))' "$q" "$v" > "$TMP/body.json"
    curl -sS --max-time 8 -X POST --data-binary @"$TMP/body.json" \
      "http://127.0.0.1:$PORT/graphql" >> "$TMP/got.txt"
    echo >> "$TMP/got.txt"
  done < "$TMP/vars.txt"
  wait_server || fail=1
  if diff -q "$TMP/want.txt" "$TMP/got.txt" >/dev/null; then
    echo "  ok    endpoint  $NTOTAL queries answered exactly as graphql-js does"
  else
    echo "  FAIL  endpoint"
    { cat "$TMP/queries.txt"; cut -f1 "$TMP/vars.txt"; } > "$TMP/labels.txt"
    paste -d'|' "$TMP/labels.txt" "$TMP/want.txt" "$TMP/got.txt" \
      | awk -F'|' '$2 != $3 { printf "        %-44s\n          oracle=%.90s\n          ours  =%.90s\n", $1, $2, $3 }' \
      | head -15
    echo "        server log:"; sed 's/^/          /' "$TMP/srv.log" | head -4
    fail=1
  fi
fi

# --- 2. the statuses, and a rude client ----------------------------------
#
# Everything above is a well-formed request from a polite client. These are the paths a
# real deployment hits and a happy-path harness never does.
if start_server 8; then
  python3 - "$PORT" > "$TMP/edge.txt" 2>&1 <<'PY'
import socket, sys, json

port = int(sys.argv[1])

def raw(chunks, pause=0.0):
    """Send a request in the given pieces and return (status line, body)."""
    import time
    s = socket.create_connection(("127.0.0.1", port), 6)
    s.settimeout(6)
    for c in chunks:
        s.sendall(c)
        if pause: time.sleep(pause)
    buf = b""
    while True:
        d = s.recv(65535)
        if not d: break
        buf += d
    s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    return head.split(b"\r\n")[0].decode(), body.decode()

def req(body, method=b"POST", path=b"/graphql", header=b"Content-Length"):
    b = body.encode()
    return [method + b" " + path + b" HTTP/1.1\r\nHost: x\r\n"
            + header + b": " + str(len(b)).encode() + b"\r\n\r\n" + b]

# A valid query, as one packet — the baseline the rude cases are compared against.
st, bd = raw(req(json.dumps({"query": "{ hello }"})))
print("baseline", st, bd)

# THE HEADERS AND THE BODY IN SEPARATE WRITES. On loopback a request arrives in one
# read, so a server that parses whatever the first read gave it passes every polite
# test. Removing the second read loop does not fail this harness without this case.
b = json.dumps({"query": "{ hello }"}).encode()
st, bd = raw([b"POST /graphql HTTP/1.1\r\nHost: x\r\nContent-Length: "
              + str(len(b)).encode() + b"\r\n\r\n", b], pause=0.05)
print("split", st, bd)

# LOWERCASE `content-length`. HTTP header names are case-insensitive; curl sends one
# spelling and this sends the other.
st, bd = raw(req(json.dumps({"query": "{ hello }"}), header=b"content-length"))
print("lowercase-header", st, bd)

# The error paths.
st, bd = raw(req("not json at all"))
print("bad-json", st, json.loads(bd)["errors"][0]["message"][:40])
st, bd = raw(req(json.dumps({"nope": 1})))
print("no-query", st, json.loads(bd)["errors"][0]["message"][:40])
st, bd = raw(req(json.dumps({"query": "{ hello }"}), method=b"GET"))
print("get", st)

# A VALID REQUEST CARRYING AN INVALID QUERY. Every case above is either a well-formed
# query or a broken request, so nothing reached the validator — poisoning the endpoint to
# skip validation and execute anyway left this harness green. The answer is a 200 with an
# `errors` array, not an HTTP error: the request succeeded as HTTP and the operation
# failed as GraphQL, the same distinction the gRPC side makes with trailers.
st, bd = raw(req(json.dumps({"query": "{ nope }"})))
print("invalid-field", st, json.loads(bd)["errors"][0]["message"])

# A query that does not PARSE, which the validator never sees.
st, bd = raw(req(json.dumps({"query": "{ unclosed "})))
print("unparseable", st, "errors" in json.loads(bd))
PY
  wait_server || fail=1
  { echo 'baseline HTTP/1.1 200 OK {"data":{"hello":"hello from Mere"}}'
    echo 'split HTTP/1.1 200 OK {"data":{"hello":"hello from Mere"}}'
    echo 'lowercase-header HTTP/1.1 200 OK {"data":{"hello":"hello from Mere"}}'
    echo 'bad-json HTTP/1.1 400 Bad Request the request body is not a JSON object'
    echo 'no-query HTTP/1.1 400 Bad Request the request body has no "query"'
    echo 'get HTTP/1.1 405 Method Not Allowed'
    echo 'invalid-field HTTP/1.1 200 OK FieldsOnCorrectType: Cannot query field "nope" on type "Query".'
    echo 'unparseable HTTP/1.1 400 Bad Request True'
  } > "$TMP/edge_want.txt"
  if diff -q "$TMP/edge_want.txt" "$TMP/edge.txt" >/dev/null; then
    echo "  ok    transport  split writes, header case, validation, and the 400 / 405 paths"
  else
    echo "  FAIL  transport"
    diff "$TMP/edge_want.txt" "$TMP/edge.txt" | sed 's/^/        /' | head -12
    echo "        server log:"; sed 's/^/          /' "$TMP/srv.log" | head -4
    fail=1
  fi
else
  echo "  FAIL  transport  the server never started"
  fail=1
fi

[ "$fail" = 0 ] && echo "graphql_server_parity: ok" || echo "graphql_server_parity: FAILED"
[ "$fail" = 0 ]
