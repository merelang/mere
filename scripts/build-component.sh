#!/usr/bin/env bash
# build-component.sh — build a WebAssembly component from a Mere source file
# using the --component Wasm backend, wasm-tools, and the
# wasi_snapshot_preview1 command adapter.
#
# Plain command programs (print / args / files) only need the adapter.
# Programs that use the socket FFI (tcp_* / udp_*) import p2 wasi:sockets
# directly, so the wasi WIT is extracted from the adapter and embedded first.
#
# Usage:
#   scripts/build-component.sh <file.mere> [out.wasm]
# Environment:
#   MERE          mere binary (default: `mere` on PATH)
#   WASI_ADAPTER  path to wasi_snapshot_preview1.command.wasm
#                 (default: the global jco install's copy)
#
# Run the result with:
#   wasmtime run -S inherit-network=y -S allow-ip-name-lookup=y <out> [args...]
#   jco run <out> [args...]
set -euo pipefail

src="${1:?usage: build-component.sh <file.mere> [out.wasm]}"
out="${2:-${src%.mere}.component.wasm}"
mere="${MERE:-mere}"

adapter="${WASI_ADAPTER:-}"
if [ -z "$adapter" ]; then
  adapter="$(npm root -g 2>/dev/null)/@bytecodealliance/jco/lib/wasi_snapshot_preview1.command.wasm"
fi
[ -f "$adapter" ] || { echo "command adapter not found; set WASI_ADAPTER=<path>" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

"$mere" -w --component "$src" > "$tmp/core.wat"
wasm-tools parse "$tmp/core.wat" -o "$tmp/core.wasm"

if grep -q 'wasi:sockets' "$tmp/core.wat"; then
  # Socket program: embed the p2 wasi:sockets types (extracted from the
  # adapter) under a world that imports the socket + io interfaces, then link
  # the adapter for the remaining wasi_snapshot_preview1 imports.
  # The wasi package version is not written here. It is read back out of the
  # module the compiler just emitted, so the world can never be embedded
  # against a version the imports do not actually use -- and a module that
  # mixed two versions would be caught here rather than at link time.
  ver="$(grep -o 'wasi:[a-z][a-z-]*/[a-z][a-z-]*@[0-9][0-9.]*' "$tmp/core.wat" \
           | sed 's/.*@//' | sort -u)" || true
  if [ -z "$ver" ]; then
    echo "no wasi imports in the emitted module" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$ver" | wc -l | tr -d ' ')" != 1 ]; then
    echo "the emitted module mixes wasi versions: $(printf '%s ' $ver)" >&2
    exit 1
  fi
  {
    cat <<WIT
package local:app;
world app {
  import wasi:sockets/instance-network@${ver};
  import wasi:sockets/tcp-create-socket@${ver};
  import wasi:sockets/tcp@${ver};
  import wasi:sockets/udp-create-socket@${ver};
  import wasi:sockets/udp@${ver};
  import wasi:sockets/ip-name-lookup@${ver};
  import wasi:io/streams@${ver};
  import wasi:io/poll@${ver};
}
WIT
    wasm-tools component wit "$adapter" | sed -n '/^package wasi:/,$p'
  } > "$tmp/app.wit"
  wasm-tools component embed --world app "$tmp/app.wit" "$tmp/core.wasm" -o "$tmp/embed.wasm"
  wasm-tools component new "$tmp/embed.wasm" --adapt "wasi_snapshot_preview1=$adapter" -o "$out"
else
  wasm-tools component new "$tmp/core.wasm" --adapt "wasi_snapshot_preview1=$adapter" -o "$out"
fi

echo "wrote $out"
