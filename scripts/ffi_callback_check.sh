#!/bin/sh
# A separately compiled C shim calls borrowed Mere closures using only the
# generated header. No duplicated struct layouts or generated-C includes.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
CC="${CC:-clang}"
command -v "$CC" >/dev/null 2>&1 || CC=cc
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat > "$T/shim.c" <<'EOF'
#include "mere_extern.h"
#include "mere_extern.h"
#include <stdlib.h>
int check_callbacks(outer h, closure_int_closure_int_int curried,
                    closure_unit_int thunk, closure_bytes_bytes echo) {
    operand input = {.mu_value = 5};
    if (h.mu_handler.mu_bias != 9) return 1;
    if (h.mu_handler.mu_apply.fn(h.mu_handler.mu_apply.env, input) != 4294967301LL) return 2;
    closure_int_int inner = curried.fn(curried.env, 3);
    if (inner.fn(inner.env, 4) != 4294967303LL) return 3;
    if (thunk.fn(thunk.env, 0) != 4294967296LL) return 5;
    mere_bytes *input_bytes = malloc(sizeof(*input_bytes) + 3);
    if (!input_bytes) return 7;
    input_bytes->len = 3;
    input_bytes->data[0] = 'a'; input_bytes->data[1] = 0; input_bytes->data[2] = 'b';
    mere_bytes *out = echo.fn(echo.env, input_bytes);
    int bad = out->len != 3 || out->data[0] != 'a' || out->data[1] != 0 || out->data[2] != 'b';
    free(input_bytes);
    if (bad) return 6;
    return 0;
}
EOF

for region in no yes; do
  cat > "$T/p.mere" <<'EOF'
type operand = { value: int };
type handler = { bias: int, apply: operand -> int };
type outer = { handler: handler };
type private_record = { hidden: int };
extern fn check_callbacks: outer -> (int -> int -> int) -> (unit -> int) -> (bytes -> bytes) -> int;
let private_value = private_record { hidden = 0 };
EOF
  if [ "$region" = yes ]; then printf 'let result = region R {\n' >> "$T/p.mere"; else printf 'let result =\n' >> "$T/p.mere"; fi
  cat >> "$T/p.mere" <<'EOF'
  let base = 4294967296 in
  let h = outer { handler = handler { bias = 9, apply = fn (v: operand) -> base + v.value } } in
  check_callbacks h (fn (x: int) -> fn (y: int) -> base + x + y)
    (fn (u: unit) -> base) (fn (b: bytes) -> b)
EOF
  if [ "$region" = yes ]; then printf '};\n' >> "$T/p.mere"; else printf ';\n' >> "$T/p.mere"; fi
  printf 'print_int (result + private_value.hidden)\n' >> "$T/p.mere"
  "$MERE" --ffi-header "$T/p.mere" > "$T/mere_extern.h"
  "$MERE" --ffi-header "$T/p.mere" > "$T/again.h"
  cmp "$T/mere_extern.h" "$T/again.h"
  if grep -q private_record "$T/mere_extern.h"; then
    echo 'ffi_callback: internal record leaked' >&2; exit 1
  fi
  "$MERE" -c "$T/p.mere" > "$T/p.c"
  # Compile the shim independently and strictly: the header must stand alone.
  "$CC" -std=c11 -Wall -Wextra -Werror -c "$T/shim.c" -o "$T/shim.o"
  for opt in 0 2; do
    "$CC" -w "-O$opt" "$T/p.c" "$T/shim.o" -lm -o "$T/prog"
    got=$("$T/prog")
    [ "$got" = 0 ] || { echo "ffi_callback: region=$region O$opt returned $got" >&2; exit 1; }
  done
  echo "ffi_callback: region=$region O0/O2 passed"
done

# A missing generated callback declaration must be observable by this gate.
sed '/} closure_bytes_bytes;/d' "$T/mere_extern.h" > "$T/broken.h"
mv "$T/broken.h" "$T/mere_extern.h"
if "$CC" -std=c11 -Werror -fsyntax-only "$T/shim.c" > "$T/poison.log" 2>&1; then
  echo 'ffi_callback: missing callback declaration was not detected' >&2; exit 1
fi
echo 'ffi_callback: missing declaration rejected'

# Diagnose unsupported boundaries before producing a partial header or IR.
reject() {
  mode=$1; expected=$2
  if "$MERE" "$mode" "$T/reject.mere" > "$T/reject.out" 2> "$T/reject.err"; then
    echo "ffi_callback: $mode accepted an unsupported boundary" >&2; exit 1
  fi
  grep -F -- "$expected" "$T/reject.err" >/dev/null || { cat "$T/reject.err" >&2; exit 1; }
  [ ! -s "$T/reject.out" ] || { echo 'ffi_callback: emitted partial output' >&2; exit 1; }
}
for source in \
  'extern fn bad: (int -> int) -> int; 0' \
  'extern fn bad: (int -> int -> int) -> int; 0' \
  'type inner = { cb: int -> int }; type outer = { value: inner }; extern fn bad: outer -> int; 0' \
  'type cb_result = { cb: int -> int }; extern fn bad: unit -> cb_result; 0' \
  'type choice = Empty | Callback of (int -> int); extern fn bad: choice -> int; 0' \
  'extern fn bad: Vec[int -> int] -> int; 0'; do
  printf '%s\n' "$source" > "$T/reject.mere"
  reject -ll 'extern `bad`: callback values are unsupported on the LLVM backend'
done
echo 'ffi_callback: LLVM rejects direct, curried and nested callback boundaries'

for source in \
  'extern fn bad: ((int * int) -> int) -> int; 0' \
  'extern fn bad: (int -> (int * int)) -> int; 0' \
  'type choice = Empty | Number of int; extern fn bad: (choice -> int) -> int; 0' \
  'extern fn bad: (Vec[int] -> int) -> int; 0' \
  'type holder = { cb: (int * int) -> int }; extern fn bad: holder -> int; 0' \
  'extern fn bad: (int * int) -> int; 0'; do
  printf '%s\n' "$source" > "$T/reject.mere"
  reject --ffi-header '--ffi-header: extern `bad` uses unsupported type'
done
echo 'ffi_callback: undefined header types rejected, including callback arguments/results'

# The extern's own parameter-list arrows are not callbacks. LLVM still emits
# ordinary multi-argument externs and records without callback fields.
printf '%s\n' 'type point = { x: int }; extern fn plain: point -> int -> int; 0' > "$T/plain.mere"
"$MERE" -ll "$T/plain.mere" > "$T/plain.ll"
grep -F '@plain(' "$T/plain.ll" >/dev/null
"$MERE" --ffi-header "$T/plain.mere" > "$T/plain.h"
"$CC" -std=c11 -Werror -x c -fsyntax-only "$T/plain.h"

# Wasm host imports use pointers into linear memory, not this C struct ABI.
# Keep that separate callback interface available to its existing host glue.
printf '%s\n' 'extern fn host_callback: (int -> int) -> int; host_callback (fn (x: int) -> x + 1)' > "$T/host.mere"
"$MERE" -w "$T/host.mere" > "$T/host.wat"
grep -F '(import "env" "host_callback"' "$T/host.wat" >/dev/null
echo 'ffi_callback: ordinary LLVM externs and separate Wasm host imports preserved'
