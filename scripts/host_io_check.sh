#!/bin/sh
# v0.1.724: credentials, interfaces and SCM_RIGHTS on a socket; a pty, a
# descriptor's termios and window size, a child that gets the pty as its
# controlling terminal; fstat of an unlinked file; stdout and stderr on a
# pipe made non-blocking -- on both native backends.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-clang}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
for probe in sockaddr/ancillary_probe tty/pty_probe stdio/eagain_probe sockaddr/sendmsg_to_probe; do
  P="$ROOT/test/$probe.mere"
  name=$(basename "$probe")
  "$MERE" -c "$P" > "$T/$name.c"
  if [ "$name" = sendmsg_to_probe ]; then
    "$CC" -O2 -w -pthread "$T/$name.c" "$ROOT/test/sockaddr/sendmsg_to_support.c" -o "$T/$name-c" -lm
  else
    "$CC" -O2 -w -pthread "$T/$name.c" -o "$T/$name-c" -lm
  fi
  "$MERE" -ll "$P" > "$T/$name.ll"
  "$MERE" --ffi-c "$P" > "$T/$name-ffi.c"
  if [ "$name" = sendmsg_to_probe ]; then
    "$CC" -O2 -w -pthread "$T/$name.ll" "$T/$name-ffi.c" "$ROOT/test/sockaddr/sendmsg_to_support.c" -o "$T/$name-llvm" -lm
  else
    "$CC" -O2 -w -pthread "$T/$name.ll" "$T/$name-ffi.c" -o "$T/$name-llvm" -lm
  fi
  for backend in c llvm; do
    (cd "$T" && sh "$ROOT/scripts/bounded.sh" 20 "./$name-$backend") > "$T/$backend.out" 2>&1 || {
      cat "$T/$backend.out"
      exit 1
    }
    case "$(cat "$T/$backend.out")" in
      *passed) echo "$name: $backend passed" ;;
      *) cat "$T/$backend.out"; exit 1 ;;
    esac
  done
done

python3 "$ROOT/scripts/spawn_failure_check.py"
