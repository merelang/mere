#!/bin/sh
# Addressed UDP, flags, source metadata, bounds and errno on both native backends.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-clang}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
P="$ROOT/test/sockaddr/datagram_probe.mere"
"$MERE" -c "$P" > "$T/probe.c"
"$CC" -O2 -w -pthread "$T/probe.c" -o "$T/c" -lm
"$MERE" -ll "$P" > "$T/probe.ll"
"$MERE" --ffi-c "$P" > "$T/ffi.c"
"$CC" -O2 -w -pthread "$T/probe.ll" "$T/ffi.c" -o "$T/llvm" -lm
printf '%s\n' 'datagrams: IPv4 and IPv6 passed' > "$T/expected"
for backend in c llvm; do
  sh "$ROOT/scripts/bounded.sh" 15 "$T/$backend" > "$T/$backend.out" 2>&1 || {
    cat "$T/$backend.out"
    exit 1
  }
  diff -u "$T/expected" "$T/$backend.out"
  echo "datagrams: $backend passed"
done
