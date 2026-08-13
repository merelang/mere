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
let buf = mem_alloc 256;
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
if ! MERE="$MERE" sh "$ROOT/scripts/build-component.sh" "$TMP/sockw.mere" \
       "$TMP/sock.component.wasm" >"$TMP/build.log" 2>&1; then
  echo "socket_parity: FAILED — the component build broke" >&2
  tail -20 "$TMP/build.log" >&2
  exit 1
fi
wasm=$(wasmtime run -S inherit-network=y "$TMP/sock.component.wasm" 2>/dev/null \
       | grep -E '^(listen|connect|read|eof) ' | tr '\n' '|')

if [ "$native" = "$wasm" ]; then
  echo "socket_parity: ok  ($(printf '%s' "$native" | tr '|' ' ' | sed 's/ $//'))"
  exit 0
fi

echo "socket_parity: FAILED" >&2
echo "  native: $native" >&2
echo "  wasm:   $wasm" >&2
exit 1
