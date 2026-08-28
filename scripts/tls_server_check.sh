#!/bin/sh
# scripts/tls_server_check.sh — a Mere program ANSWERS a TLS connection.
#
# v0.1.338. Until now the C backend could only DIAL TLS (`tcp_starttls`). It
# could not terminate one, so every web dogfood served plaintext -- and no
# document in the project said so, recommended a proxy, or mentioned TLS for
# serving at all. There was no workaround to notice. The app worked, the gate
# was green, and the thing the language could not do was invisible because
# nobody had tried to do it.
#
# THE ORACLE IS SOMEONE ELSE'S TLS. curl and `openssl s_client` are two
# independent client implementations that refuse a handshake we get wrong, and
# nothing in this repository can make them lenient. Note the ABSENCE of `-k`:
# the certificate is verified against the CA the harness generated, so this
# also asserts that the certificate the server presents is the one
# `tls_server_init` was handed -- a server that loaded nothing and negotiated
# an anonymous cipher would still "complete a handshake".
#
# It also asserts the NEGATIVE, because a program that quietly fell back to
# plaintext would pass a check that only ever spoke TLS to it (check 2), and
# so would one that answered before the handshake finished.
#
# The certificate is generated per run and never committed: a private key in a
# public repository is a finding whatever it protects.
#
# Skips (exit 0) without a C compiler, openssl, or curl.
#
# Usage:
#   sh scripts/tls_server_check.sh

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=${PORT:-18443}
PORT2=$((PORT + 1))

for tool in openssl curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "tls_server_check: $tool not found — skipping (this check is optional)"
    exit 0
  fi
done
if ! command -v clang >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
  echo "tls_server_check: no C compiler — skipping (this check is optional)"
  exit 0
fi
CC=$(command -v clang || command -v cc)

# OpenSSL headers. Homebrew keeps them off the default include path; on Linux
# libssl-dev puts them where the compiler already looks.
if [ -z "$SSL_PREFIX" ] && command -v brew >/dev/null 2>&1; then
  SSL_PREFIX=$(brew --prefix openssl@3 2>/dev/null || true)
fi
SSL_FLAGS=""
if [ -n "$SSL_PREFIX" ] && [ -d "$SSL_PREFIX/include" ]; then
  SSL_FLAGS="-I$SSL_PREFIX/include -L$SSL_PREFIX/lib"
fi

WORK=$(mktemp -d)
SRVPID=""
cleanup() {
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  :
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "PASS  $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL  $1"; }

# ---- the certificate (generated, never committed) ----------------------
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 2 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 \
  || { echo "tls_server_check: openssl req failed — skipping"; exit 0; }

# ---- build -------------------------------------------------------------
"$MERE" -c "$ROOT/test/tls/https_server.mere" > "$WORK/https.c"
if ! $CC -O1 -o "$WORK/https" "$WORK/https.c" $SSL_FLAGS -lssl -lcrypto -lm 2>"$WORK/cc.log"; then
  echo "tls_server_check: could not link against OpenSSL — skipping"
  sed -n '1,10p' "$WORK/cc.log"
  exit 0
fi

start_server() {
  # $1 = port, $2 = cert, $3 = key, $4 = how many requests to answer
  MERE_TLS_CERT="$2" MERE_TLS_KEY="$3" MERE_TLS_PORT="$1" MERE_TLS_REQUESTS="$4" \
    "$WORK/https" > "$WORK/srv.log" 2>&1 &
  SRVPID=$!
}

# ---- one server, five requests, four kinds of client --------------------
# A generous budget and an explicit kill, rather than "exits after exactly the
# number we expect": the budget is not what is under test here, and a gate that
# depends on it turns a wrong answer into a hang.
start_server "$PORT" "$WORK/cert.pem" "$WORK/key.pem" 5

# 1. plaintext to the TLS port must NOT be answered.
plain=$(curl -sS --retry 15 --retry-delay 1 --retry-connrefused --max-time 8 \
          -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/plain" 2>/dev/null || true)
if [ "$plain" = "200" ]; then
  bad "a plaintext request got a 200 — the server is not requiring TLS"
else
  ok "plaintext to the TLS port is refused (http_code=$plain)"
fi

# 2. curl, WITH certificate verification. No -k anywhere in this file.
body=$(curl -sS --cacert "$WORK/cert.pem" --resolve "localhost:$PORT:127.0.0.1" \
         --retry 10 --retry-delay 1 --retry-connrefused --max-time 8 \
         -w '\nHTTP=%{http_code}' \
         "https://localhost:$PORT/hello/world" 2>&1 || true)
echo "$body" | grep -q 'HTTP=200' \
  && ok "curl completed a verified TLS handshake and got 200" \
  || bad "curl did not get 200 (got: $(echo "$body" | tr '\n' ' ' | cut -c1-160))"

# 3. the body came back through the TLS layer intact.
echo "$body" | grep -q 'path=/hello/world' \
  && ok "the request path survived the TLS layer intact" \
  || bad "the response body did not echo the request path"

# 4. the SAME request WITHOUT the CA must fail.
#
# This is what makes check 2 mean anything. An earlier draft asserted
# curl's %{ssl_verify_result} == 0 instead -- and that field is 0 when curl
# never connected at all, so it stayed green under a poison that removed the
# handshake entirely. Verification only proves something if the unverified
# case is shown to fail: a server presenting a certificate that chains to
# nothing must be REJECTED by a client using the system CA store.
nocacert=$(curl -sS --resolve "localhost:$PORT:127.0.0.1" --max-time 8 \
             -o /dev/null -w '%{http_code}' \
             "https://localhost:$PORT/nocacert" 2>/dev/null || true)
if [ "$nocacert" = "200" ]; then
  bad "a client that does not trust our CA still got 200 — verification is not happening"
else
  ok "a client without our CA is rejected (http_code=$nocacert) — check 2 is a real verification"
fi

# 5. the listener survived. Two handshakes have now failed on this process
# (checks 1 and 4). Asserting it by asking for another answer, because the
# earlier draft simply PRINTED that the listener survived -- and printed it
# under a poison that had killed the listener.
again=$(curl -sS --cacert "$WORK/cert.pem" --resolve "localhost:$PORT:127.0.0.1" \
          --max-time 8 -o /dev/null -w '%{http_code}' \
          "https://localhost:$PORT/again" 2>/dev/null || true)
[ "$again" = "200" ] \
  && ok "the listener survived two failed handshakes and answered again" \
  || bad "the server stopped answering after a failed handshake (http_code=$again)"

kill "$SRVPID" 2>/dev/null || true; SRVPID=""

# ---- 3. a second, independent TLS client -------------------------------
# On a DIFFERENT port, which is also the assertion that the port came from the
# environment: nothing in the binary knows about $PORT2.
start_server "$PORT2" "$WORK/cert.pem" "$WORK/key.pem" 1
# Readiness without spending the request budget: a PLAINTEXT connect fails the
# handshake, so the server loops back to accept without counting it. (A probe
# that completed a handshake would eat the one request this server will answer
# -- which is how the first draft of this gate stalled.)
curl -sS --retry 15 --retry-delay 1 --retry-connrefused --max-time 5 \
     -o /dev/null "http://127.0.0.1:$PORT2/ready" >/dev/null 2>&1 || true
sout=$(printf 'GET /s_client HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' \
        | sh "$ROOT/scripts/bounded.sh" 20 openssl s_client -connect "127.0.0.1:$PORT2" \
            -servername localhost -CAfile "$WORK/cert.pem" -verify_return_error -quiet 2>&1 || true)
echo "$sout" | grep -q 'path=/s_client' \
  && ok "openssl s_client (an independent implementation) also got a verified answer" \
  || bad "openssl s_client did not get the response (got: $(echo "$sout" | tr '\n' ' ' | cut -c1-160))"
kill "$SRVPID" 2>/dev/null || true; SRVPID=""

# ---- 4. a certificate that is not there is an error, not a silent start --
# The reason tls_server_init and tcp_accept_tls are two calls: a server that
# discovered its bad certificate only on the first connection would look
# healthy until a user arrived.
# BOUNDED. This run is only fast because the certificate is expected to be
# rejected; if it ever stops being rejected the server listens forever, and an
# unbounded gate turns a wrong answer into a hang. (It did: dropping both key
# checks made this line run until the harness was killed.)
out=$(MERE_TLS_CERT="$WORK/nope.pem" MERE_TLS_KEY="$WORK/key.pem" \
      MERE_TLS_PORT="$PORT2" MERE_TLS_REQUESTS=1 \
      sh "$ROOT/scripts/bounded.sh" 15 "$WORK/https" 2>&1 || true)
echo "$out" | grep -q 'tls_server_init failed' \
  && ok "a missing certificate fails at init, before the socket is opened" \
  || bad "a missing certificate did not fail at init (got: $(echo "$out" | tr '\n' ' '))"
echo "$out" | grep -q 'listening' \
  && bad "it listened anyway, with no usable certificate" \
  || ok "and it did not listen"

# ---- 5. a key that does not match the certificate ----------------------
# TWO LINES CATCH THIS, EITHER ALONE SUFFICES, established by poisoning them
# separately: SSL_CTX_use_PrivateKey_file already refuses a key inconsistent
# with the certificate loaded before it, and SSL_CTX_check_private_key catches
# it too. So neither is dead code and neither is individually detectable here --
# only removing BOTH turns this check red. Recorded because "poison it and the
# gate stayed green" otherwise reads as a useless check.
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/other.key" -out "$WORK/other.crt" \
  -days 2 -nodes -subj "/CN=elsewhere" >/dev/null 2>&1
out=$(MERE_TLS_CERT="$WORK/cert.pem" MERE_TLS_KEY="$WORK/other.key" \
      MERE_TLS_PORT="$PORT2" MERE_TLS_REQUESTS=1 \
      sh "$ROOT/scripts/bounded.sh" 15 "$WORK/https" 2>&1 || true)
echo "$out" | grep -q 'tls_server_init failed' \
  && ok "a key that does not match the certificate is refused at init" \
  || bad "a mismatched key was accepted (got: $(echo "$out" | tr '\n' ' '))"

# ---- 6. contrib/http, the module every web program here actually uses ---
# Separate from checks 1-5 on purpose: routing `tcp_read` through TLS and
# routing the runtime's own accept loop through TLS are different code paths,
# and only the second one is what mere-blog calls.
"$MERE" -c "$ROOT/test/tls/https_router.mere" > "$WORK/router.c"
if $CC -O1 -o "$WORK/router" "$WORK/router.c" $SSL_FLAGS -lssl -lcrypto -lm 2>"$WORK/cc2.log"; then
  printf 'some content over tls\n' > "$WORK/payload.txt"
  MERE_TLS_CERT="$WORK/cert.pem" MERE_TLS_KEY="$WORK/key.pem" MERE_TLS_PORT="$PORT2" \
    MERE_TLS_FILE="$WORK/payload.txt" "$WORK/router" > "$WORK/router.log" 2>&1 &
  SRVPID=$!

  page=$(curl -sS --cacert "$WORK/cert.pem" --resolve "localhost:$PORT2:127.0.0.1" \
           --retry 15 --retry-delay 1 --retry-connrefused --max-time 8 \
           -w '\nHTTP=%{http_code}' "https://localhost:$PORT2/" 2>&1 || true)
  echo "$page" | grep -q 'hello over tls' \
    && ok "contrib/http's router answered over verified TLS" \
    || bad "contrib/http did not answer over TLS (got: $(echo "$page" | tr '\n' ' ' | cut -c1-160))"

  # THE ONE THAT CATCHES A HALF-FIX. http_send_file writes straight to the
  # connection rather than returning a body, so it is the site most likely to
  # be left calling write() while every page still renders correctly.
  filed=$(curl -sS --cacert "$WORK/cert.pem" --resolve "localhost:$PORT2:127.0.0.1" \
            --max-time 8 "https://localhost:$PORT2/file" 2>&1 || true)
  echo "$filed" | grep -q 'some content over tls' \
    && ok "http_send_file's bytes arrived intact over TLS" \
    || bad "http_send_file did not deliver over TLS (got: $(echo "$filed" | tr '\n' ' ' | cut -c1-160))"

  st=$(curl -sS --cacert "$WORK/cert.pem" --resolve "localhost:$PORT2:127.0.0.1" \
         --max-time 8 -o /dev/null -w '%{http_code}' "https://localhost:$PORT2/nope" 2>&1 || true)
  [ "$st" = "404" ] \
    && ok "status and headers survive the TLS path (404 route)" \
    || bad "the 404 route did not come back as 404 (got: $st)"

  rplain=$(curl -sS --max-time 6 -o /dev/null -w '%{http_code}' \
             "http://127.0.0.1:$PORT2/" 2>/dev/null || true)
  [ "$rplain" = "200" ] \
    && bad "http_serve_tls answered a plaintext request with 200" \
    || ok "http_serve_tls refuses plaintext (http_code=$rplain)"

  kill "$SRVPID" 2>/dev/null || true; SRVPID=""
else
  bad "test/tls/https_router.mere did not build: $(head -3 "$WORK/cc2.log" | tr '\n' ' ')"
  bad "(and so the four contrib/http checks did not run)"
  bad "(placeholder)"
  bad "(placeholder)"
fi

# ---- 6b. TLS IS OPT-IN, and a plaintext server does not pay for it ---------
# The C backend links OpenSSL into a program that DECLARES a TLS extern, and an
# `import` declares everything the imported module declares. v0.1.338 put
# `http_serve_tls` in http.mere and so made EVERY contrib/http program --
# plaintext ones included -- require OpenSSL headers to build. It shipped,
# because the app that would have shown it (mere-blog) already links OpenSSL
# for Postgres, and because this property had no check.
#
# Checked on the emitted C rather than by linking, so it is the same question on
# a machine that happens to have libssl installed.
cat > "$WORK/plain_http.mere" <<EOF
import "$ROOT/contrib/http/http.mere";
import "$ROOT/contrib/http/router.mere";
let index_h = fn (req: str) -> "plaintext";
let miss_h = fn (req: str) -> "not found";
let _ = http_serve 1 (router [route "GET" "/" index_h] miss_h);
0
EOF
if "$MERE" -c "$WORK/plain_http.mere" > "$WORK/plain_http.c" 2>"$WORK/plain_http.err"; then
  if grep -q 'openssl/' "$WORK/plain_http.c"; then
    bad "a plaintext contrib/http program pulls in OpenSSL — TLS is not opt-in"
  else
    ok "a plaintext contrib/http program needs no OpenSSL (TLS is opt-in)"
  fi
else
  bad "the plaintext contrib/http program did not compile: $(head -2 "$WORK/plain_http.err" | tr '\n' ' ')"
fi
# ...and the opposite, so the check above is not vacuous: importing the TLS
# module must produce the dependency.
if grep -q 'openssl/' "$WORK/router.c" 2>/dev/null; then
  ok "importing http/tls.mere does produce the OpenSSL dependency"
else
  bad "the TLS program has no OpenSSL dependency — the check above proves nothing"
fi

# ---- 7. the OTHER host --------------------------------------------------
# contrib/http has two implementations -- the C runtime above and
# scripts/run_http_server.js -- and the glue comment claims they agree. A claim
# with no check behind it is how this broke: run_http_server.js hand-copied
# run_wasm.js's env imports under a comment saying it reused them, so when
# v0.1.277 added `__lang_float_of_str_ok` only the maintained copy got it, and
# the HTTP host stopped being able to instantiate ANY Mere module. Nothing
# noticed for months because no gate ever started it.
#
# Check 14 is deliberately the weakest possible assertion -- "a Mere program
# starts at all under this host" -- because that is the assertion that was false.
if command -v node >/dev/null 2>&1 && command -v wat2wasm >/dev/null 2>&1; then
  # The paths are interpolated rather than read from the environment because
  # plain Wasm answers None to env_var on every host (see docs; the component
  # backend is the one with an environment). The MODULE under test is real.
  cat > "$WORK/nodehost.mere" <<EOF
import "$ROOT/contrib/http/http.mere";
extern fn http_serve_tls: int -> str -> str -> (str -> str) -> unit;
let h = fn (req: str) -> "node host says: " ++ req ++ "\n";
let _ = http_serve_tls $PORT2 "$WORK/cert.pem" "$WORK/key.pem" h;
0
EOF
  cat > "$WORK/nodehost_plain.mere" <<EOF
import "$ROOT/contrib/http/http.mere";
let h = fn (req: str) -> "node host says: " ++ req ++ "\n";
let _ = http_serve $PORT2 h;
0
EOF
  built=1
  for m in nodehost_plain nodehost; do
    "$MERE" -w "$WORK/$m.mere" > "$WORK/$m.wat" 2>"$WORK/$m.err" \
      && wat2wasm --enable-tail-call "$WORK/$m.wat" -o "$WORK/$m.wasm" 2>>"$WORK/$m.err" \
      || built=0
  done
  if [ "$built" -eq 1 ]; then
    node "$ROOT/scripts/run_http_server.js" "$WORK/nodehost_plain.wasm" > "$WORK/node.log" 2>&1 &
    SRVPID=$!
    np=$(curl -sS --retry 15 --retry-delay 1 --retry-connrefused --max-time 8 \
           "http://127.0.0.1:$PORT2/node" 2>&1 || true)
    grep -q 'LinkError\|not a function\|requires a callable' "$WORK/node.log" \
      && bad "the Node HTTP host cannot instantiate a Mere module ($(head -1 "$WORK/node.log" | cut -c1-120))" \
      || ok "the Node HTTP host instantiates a Mere module"
    echo "$np" | grep -q 'node host says' \
      && ok "the Node HTTP host serves the same program over plaintext" \
      || bad "the Node HTTP host did not answer (got: $(echo "$np" | tr '\n' ' ' | cut -c1-120))"
    kill "$SRVPID" 2>/dev/null || true; SRVPID=""

    node "$ROOT/scripts/run_http_server.js" "$WORK/nodehost.wasm" > "$WORK/nodetls.log" 2>&1 &
    SRVPID=$!
    nt=$(curl -sS --cacert "$WORK/cert.pem" --resolve "localhost:$PORT2:127.0.0.1" \
           --retry 15 --retry-delay 1 --retry-connrefused --max-time 8 \
           "https://localhost:$PORT2/node" 2>&1 || true)
    echo "$nt" | grep -q 'node host says' \
      && ok "the Node HTTP host terminates TLS too — both hosts run the same program" \
      || bad "the Node host did not serve over TLS (got: $(echo "$nt" | tr '\n' ' ' | cut -c1-120))"
    kill "$SRVPID" 2>/dev/null || true; SRVPID=""
  else
    bad "the Node-host programs did not build: $(head -2 "$WORK/nodehost.err" | tr '\n' ' ')"
    bad "(and so the remaining two Node-host checks did not run)"
    bad "(placeholder)"
  fi
  NODE_CHECKS=3
else
  echo "tls_server_check: node or wat2wasm missing — the three Node-host checks are SKIPPED, not passed"
  NODE_CHECKS=0
fi

# HOW MANY CHECKS THERE ARE, asserted. `set -e` plus a `kill` on an
# already-exited server made an earlier draft of this script stop after check 2
# and exit 0: five PASS lines, no summary, and a green CI. A gate that reports
# only what it managed to reach cannot tell "everything passed" from "it stopped
# early". Raise this number in the same commit that adds a check.
EXPECTED=$((15 + NODE_CHECKS))
echo
echo "tls_server_check: $pass passed, $fail failed, of $EXPECTED checks"
if [ $((pass + fail)) -ne "$EXPECTED" ]; then
  echo "tls_server_check: only $((pass + fail)) of $EXPECTED checks ran — the script stopped early"
  exit 1
fi
[ "$fail" -eq 0 ] || exit 1
echo "tls_server_check: ok"
