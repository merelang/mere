#!/bin/sh
# scripts/component_parity.sh -- the component-only runtime sections, run.
#
# WHAT THIS IS. `mere -w --component` emits sections that plain `-w` never
# does: `env_var` reads wasi environ, `read_stdin` reads wasi fd_read, and the
# socket FFI brings in-module helpers. test/parity/ compiles with plain `-w`,
# so none of those are reachable there -- and a runtime section nobody emits is
# never validated, linked or run. Q-068 and Q-069 were both exactly that.
#
# So this runs them, against the interpreter, the way parity does:
#
#   env_var      one variable set, one deliberately unset. Both arms of the
#                option, and an answer that does not depend on the machine.
#   read_stdin   a fixed payload on stdin. This is also why a parity run could
#                not host it: read_stdin blocks until EOF, so a harness that
#                feeds nothing would HANG rather than fail.
#   socket FFI   built and validated only, and it opens nothing. Talking to a
#                live peer is scripts/socket_parity.sh's job; keeping the
#                emitted helpers valid on an ordinary run is this one's, and
#                the two must not be confused for each other.
#
# SKIPS LOUDLY. The component toolchain (wasm-tools + a wasi command adapter +
# wasmtime) is not everywhere. A missing tool prints a skip line and exits 0 --
# it never silently reports success for something it did not run.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
BOUND="${COMPONENT_TIMEOUT:-120}"
[ -x "$MERE" ] || { echo "component_parity: $MERE not found -- run 'dune build'" >&2; exit 1; }

for t in wasm-tools wasmtime; do
  command -v "$t" >/dev/null 2>&1 || { echo "component_parity: SKIP (no $t)"; exit 0; }
done
adapter="${WASI_ADAPTER:-$(npm root -g 2>/dev/null)/@bytecodealliance/jco/lib/wasi_snapshot_preview1.command.wasm}"
[ -f "$adapter" ] || { echo "component_parity: SKIP (no wasi command adapter; set WASI_ADAPTER)"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ran=0

# NOT `sh scripts/build-component.sh`: that script declares
# `#!/usr/bin/env bash` and uses `set -o pipefail`, which dash does not have. On
# macOS /bin/sh is bash and this passed; on Ubuntu /bin/sh is dash and every
# component build failed with "Illegal option -o pipefail". So this gate was red
# in CI while green here -- and because it is a step in the middle of the
# workflow, the twenty-one gates AFTER it were SKIPPED rather than run, for
# every commit since it was added. Invoke it through its own shebang.
build() {  # build <name>
  MERE="$MERE" WASI_ADAPTER="$adapter" \
    "$ROOT/scripts/build-component.sh" "$ROOT/test/component/$1.mere" "$TMP/$1.wasm" \
    >"$TMP/$1.build" 2>&1
}

# --- env_var: one set, one unset -------------------------------------------
ran=$((ran + 1))
if ! build env_var; then
  echo "FAIL component_parity[env_var]: build failed"; sed -n '1,3p' "$TMP/env_var.build"; fails=$((fails + 1))
else
  want="$(MERE_PROBE=hello sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" "$ROOT/test/component/env_var.mere" 2>&1)"
  got="$(sh "$ROOT/scripts/bounded.sh" "$BOUND" wasmtime run --env MERE_PROBE=hello "$TMP/env_var.wasm" 2>&1)"
  if [ "$want" != "$got" ]; then
    echo "FAIL component_parity[env_var]: interpreter and component disagree"
    echo "  interp:    $(printf '%s' "$want" | tr '\n' '|')"
    echo "  component: $(printf '%s' "$got" | tr '\n' '|')"
    fails=$((fails + 1))
  else
    echo "  ok    env_var      $(printf '%s' "$got" | tr '\n' ' ')"
  fi
fi

# --- read_stdin: a fixed payload -------------------------------------------
ran=$((ran + 1))
payload='abcdef'
if ! build read_stdin; then
  echo "FAIL component_parity[read_stdin]: build failed"; sed -n '1,3p' "$TMP/read_stdin.build"; fails=$((fails + 1))
else
  want="$(printf '%s' "$payload" | sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" "$ROOT/test/component/read_stdin.mere" 2>&1)"
  got="$(printf '%s' "$payload" | sh "$ROOT/scripts/bounded.sh" "$BOUND" wasmtime run "$TMP/read_stdin.wasm" 2>&1)"
  if [ "$want" != "$got" ]; then
    echo "FAIL component_parity[read_stdin]: interpreter and component disagree"
    echo "  interp:    $(printf '%s' "$want" | tr '\n' '|')"
    echo "  component: $(printf '%s' "$got" | tr '\n' '|')"
    fails=$((fails + 1))
  else
    echo "  ok    read_stdin   $(printf '%s' "$got" | tr '\n' ' ')"
  fi
fi

# --- socket FFI: the emitted helpers must validate and the module must run ---
ran=$((ran + 1))
if ! build socket_ffi_shape; then
  echo "FAIL component_parity[socket_ffi]: build failed -- the emitted socket helpers do not validate"
  sed -n '1,3p' "$TMP/socket_ffi_shape.build"; fails=$((fails + 1))
else
  want="$(sh "$ROOT/scripts/bounded.sh" "$BOUND" "$MERE" "$ROOT/test/component/socket_ffi_shape.mere" 2>&1)"
  got="$(sh "$ROOT/scripts/bounded.sh" "$BOUND" wasmtime run "$TMP/socket_ffi_shape.wasm" 2>&1)"
  if [ "$want" != "$got" ]; then
    echo "FAIL component_parity[socket_ffi]: interpreter and component disagree"
    echo "  interp:    $(printf '%s' "$want" | tr '\n' '|')"
    echo "  component: $(printf '%s' "$got" | tr '\n' '|')"
    fails=$((fails + 1))
  else
    echo "  ok    socket_ffi   built, validated, ran (opens nothing -- see socket_parity.sh)"
  fi
fi

if [ "$fails" -gt 0 ]; then
  echo "component_parity: $fails of $ran failed"
  exit 1
fi
echo "component_parity: ok ($ran programs)"
