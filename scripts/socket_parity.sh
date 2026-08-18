#!/bin/sh
# scripts/socket_parity.sh — the same socket program, on the native backend and on
# Wasm, producing the same output.
#
# `scripts/parity.sh` runs eighty-odd programs across four backends and none of them
# opens a socket, because a socket program needs two endpoints and a host that will
# grant a network. So the sockets were the one capability with a Wasm implementation
# nobody had ever run: `tcp_listen` through `tcp_close` are all there, backed by p2
# `wasi:sockets`, and until this script no program had exercised them.
#
# What running them found: `tcp_set_timeout` compiled to a helper that did nothing
# and returned the same 0 the C version returns on success, so a program that set a
# deadline blocked forever on the next read. That is refused at codegen now, which
# is why this program does not set one.
#
# Still not the same on both, and deliberately not asserted here: on Wasm a read that
# fails returns 0, the same value C uses for a clean end of stream. Distinguishing
# them means decoding WASI's stream-error variant rather than its is-error bit.
#
# Skips (exit 0) without a C compiler, or without the Wasm component toolchain
# (wasm-tools + wasmtime + the WASI adapter).
#
# Usage:
#   sh scripts/socket_parity.sh

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=${PORT:-7941}

if ! command -v clang >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
  echo "socket_parity: no C compiler — skipping (this check is optional)"
  exit 0
fi
CC=$(command -v clang || command -v cc)

for tool in wasm-tools wasmtime; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "socket_parity: $tool not found — skipping (this check is optional)"
    exit 0
  fi
done

if [ ! -x "$MERE" ]; then
  echo "socket_parity: $MERE not found — run dune build first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A round trip against itself: listen, dial, accept, write, read, close, and read
# again to see the end of the stream. Every socket call the backends implement,
# and nothing that needs a clock.
cat > "$TMP/sock.mere" <<EOF
extern fn tcp_listen: int -> int;
extern fn tcp_accept: int -> int;
extern fn tcp_connect: str -> int -> int;
extern fn tcp_read: int -> int -> int -> int;
extern fn tcp_write: int -> int -> int -> int;
extern fn tcp_close: int -> unit;
extern fn mem_alloc: int -> int;
extern fn mem_copy_str: int -> int -> str -> int;
extern fn mem_to_str: int -> int -> str;

let srv = tcp_listen $PORT;
let _ = print ("listen " ++ str_of_int (if srv >= 0 then 1 else 0));
let cli = tcp_connect "127.0.0.1" $PORT;
let _ = print ("connect " ++ str_of_int (if cli >= 0 then 1 else 0));
let acc = tcp_accept srv;
let buf = mem_alloc 4096;
let n = mem_copy_str buf 0 "ping";
let _ = tcp_write cli buf n;
let got = tcp_read acc buf 256;
let _ = print ("read " ++ str_of_int got ++ " " ++ mem_to_str buf got);
let _ = tcp_close cli;
print ("eof " ++ str_of_int (tcp_read acc buf 256))
EOF

"$MERE" -c "$TMP/sock.mere" > "$TMP/sock.c"
(cd "$TMP" && "$CC" -O2 -w sock.c -o sock_native)
native=$("$TMP/sock_native" | grep -E '^(listen|connect|read|eof) ' | tr '\n' '|')

# A different port for the Wasm run: the native one may still be in TIME_WAIT.
sed "s/$PORT/$((PORT + 1))/g" "$TMP/sock.mere" > "$TMP/sockw.mere"
# A failure here used to exit 0. It cannot mean "toolchain absent" — that was
# checked above and the script already skipped for it — so by this point a failed
# component build is a failed component build, and reporting it as a skip made a
# real break look like an environment that was merely incomplete.
#
# Executed directly rather than through `sh`, which is not a style choice:
# build-component.sh declares `#!/usr/bin/env bash` and uses `set -o pipefail`,
# which its pipeline needs — without it a failing `wasm-tools component wit`
# would be swallowed by the `sed` after it and produce an empty WIT. Prefixing
# `sh` overrides that shebang, and on a system where /bin/sh is dash the script
# died on the `set` line. macOS never showed it, because there /bin/sh is bash.
if ! MERE="$MERE" "$ROOT/scripts/build-component.sh" "$TMP/sockw.mere" \
       "$TMP/sock.component.wasm" >"$TMP/build.log" 2>&1; then
  echo "socket_parity: FAILED — the component build broke" >&2
  tail -20 "$TMP/build.log" >&2
  exit 1
fi
wasm=$(wasmtime run -S inherit-network=y "$TMP/sock.component.wasm" 2>/dev/null \
       | grep -E '^(listen|connect|read|eof) ' | tr '\n' '|')

if [ "$native" != "$wasm" ]; then
  echo "socket_parity: FAILED" >&2
  echo "  native: $native" >&2
  echo "  wasm:   $wasm" >&2
  exit 1
fi
echo "  ok    round trip  ($(printf '%s' "$native" | tr '|' ' ' | sed 's/ $//'))"

# --- the arena's bytes bridge (Q-044) -------------------------------------
#
# `mem_to_bytes` / `mem_copy_bytes` are the arena's two directions for data that may
# contain a ZERO BYTE — which `mem_to_str` cannot carry, because it stops there, and
# which every binary protocol has. They belong in this harness rather than in
# test/parity because they are externs: the interpreter has no mock for them, so a
# parity test would SKIP rather than check.
#
# The payload is chosen to break the old workaround: a zero byte first, a zero in the
# middle, and a high byte. Nothing here opens a socket, but declaring an arena extern
# is what turns on the component's in-module helpers, so both backends exercise the
# same path they would on a real connection.
cat > "$TMP/ab.mere" <<'MERE'
extern fn mem_alloc: int -> int;
extern fn mem_to_bytes: int -> int -> bytes;
extern fn mem_copy_bytes: int -> int -> bytes -> int;

// NOT named `show`: a user binding of that name breaks the PRELUDE on every
// compiled backend, because the prelude calls `show` itself and the shadow takes
// over there too. Three lines reproduce it; recorded as an open question.
let dump = fn (label: str, b: bytes) -> print (label ++ " " ++ hex_of_bytes b);

let buf = mem_alloc 4096;
let rt = fn (label: str, hex: str) ->
  let src = bytes_of_hex hex in
  let n = mem_copy_bytes buf 0 src in
  let back = mem_to_bytes buf n in
  print (label ++ " " ++ str_of_int n ++ " " ++ hex_of_bytes back
         ++ (if hex_of_bytes back == hex then " same" else " DIFFERENT"));
let _ = rt "ab-nul-first" "00ff41";
let _ = rt "ab-nul-mid" "41004200ff";
let _ = rt "ab-empty" "";
let _ = rt "ab-all-high" "fffefdfc";
let _ = rt "ab-long" "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
// LONGER THAN 255 BYTES. Poisoning `mem_copy_bytes` to read the length with
// `i32.load8_u` instead of `i32.load` went unnoticed until this existed: on a
// little-endian machine the low byte of a length under 256 IS the length, so every
// payload in the corpus agreed. 300 bytes is the first size that does not.
let rec rep = fn (n: int, acc: str) -> if n <= 0 then acc else rep (n - 1) (acc ++ "5a");
let _ = rt "ab-300" (rep 300 "");
let _ = rt "ab-256" (rep 256 "");
let _ = rt "ab-255" (rep 255 "");
// An offset write, so the `off` parameter is not always zero.
let src = bytes_of_hex "aabb";
let _ = mem_copy_bytes buf 8 src;
let _ = dump "ab-offset" (mem_to_bytes (buf + 8) 2);
print "ab-done"
MERE

"$MERE" -c "$TMP/ab.mere" > "$TMP/ab.c" 2>"$TMP/ab.err" || {
  echo "socket_parity: FAILED — the arena-bytes program did not compile" >&2
  head -4 "$TMP/ab.err" >&2; exit 1; }
"$CC" -O1 -w "$TMP/ab.c" -o "$TMP/ab.bin" 2>"$TMP/ab.cc" || {
  echo "socket_parity: FAILED — the arena-bytes C did not build" >&2
  grep error: "$TMP/ab.cc" | head -4 >&2; exit 1; }
ab_native=$("$TMP/ab.bin" | grep -E '^ab-' | tr '\n' '|')

if ! MERE="$MERE" "$ROOT/scripts/build-component.sh" "$TMP/ab.mere" \
      "$TMP/ab.component.wasm" > "$TMP/abbuild.log" 2>&1; then
  echo "socket_parity: FAILED — the arena-bytes component build broke" >&2
  tail -20 "$TMP/abbuild.log" >&2; exit 1
fi
ab_wasm=$(wasmtime run "$TMP/ab.component.wasm" 2>/dev/null | grep -E '^ab-' | tr '\n' '|')

if [ "$ab_native" != "$ab_wasm" ]; then
  echo "socket_parity: FAILED — the arena's bytes bridge differs between backends" >&2
  echo "  native: $ab_native" >&2
  echo "  wasm:   $ab_wasm" >&2
  exit 1
fi
case "$ab_native" in
  *DIFFERENT*)
    echo "socket_parity: FAILED — a payload did not survive the arena round trip" >&2
    echo "  $ab_native" >&2; exit 1 ;;
esac
echo "  ok    bytes bridge  9 payloads (zero / high / >255 bytes), C and wasm agree"

echo "socket_parity: ok"
exit 0
