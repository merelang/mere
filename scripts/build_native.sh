#!/bin/sh
# scripts/build_native.sh <file.mere> <out> -- build a program that calls the
# externs the compiler implements itself, on the backend MERE_BACKEND names:
# `c` (the default: the runtime is inside the emitted C) or `llvm` (the IR,
# linked against the same runtime as `mere --ffi-c` prints it, v0.1.670).
#
# The probes of those externs (fdio, filestat, proclimit, procsig) build
# through this, so scripts/llvm_ffi_check.sh runs each of them -- with its own
# expected transcript -- on LLVM as well. Exit 1 with the reason on stderr.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
src=$1 out=$2
case "${MERE_BACKEND:-c}" in
  c)
    "$MERE" -c "$src" > "$out.c" || { echo "mere -c refused $src" >&2; exit 1; }
    "${CC:-cc}" -O1 -w "$out.c" -o "$out" || { echo "the C compiler refused the emitted C" >&2; exit 1; } ;;
  llvm)
    "$MERE" -ll "$src" > "$out.ll" || { echo "mere -ll refused $src" >&2; exit 1; }
    "$MERE" --ffi-c "$src" > "${out}_ffi.c" || { echo "mere --ffi-c refused $src" >&2; exit 1; }
    "${LLVM_CC:-clang}" -O1 -w "$out.ll" "${out}_ffi.c" -o "$out" -lm -lpthread \
      || { echo "clang refused the IR and its runtime" >&2; exit 1; } ;;
  *) echo "build_native: MERE_BACKEND is c or llvm, not ${MERE_BACKEND}" >&2; exit 1 ;;
esac
