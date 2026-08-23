#!/bin/sh
# scripts/lib_check.sh — the library boundary is what it claims to be.
#
# `mere -c --lib` emits a shared-library translation unit: no main, a small
# C ABI boundary (mere_lib_init / mere_lib_shutdown / mere_lib_free + one
# mere_<stem>_<fn> wrapper per exportable entry-file function), everything
# else static. This gate checks the claim from the OUTSIDE, the way a host
# would meet it:
#
#   1. the emitted C builds as a shared object (-fPIC -shared)
#   2. `nm` shows ONLY the boundary's names — "everything else is static"
#      is a linkage claim, and linkage is checked with a linker's eyes,
#      not by grepping the C text
#   3. a C host links against the .so, calls each wrapper (twice — the
#      second call must not re-run module init), and its output matches
#      the values the interpreter computes for the same functions
#   4. the manifest names what it skipped, with a reason — a silently
#      missing export reads as "covered"
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "lib_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "lib_check: no C compiler" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/demo.mere" <<'MERE'
let add2 = fn (a: int) -> fn (b: int) -> a + b;
let scale = fn (x: float) -> fn (k: float) -> x * k;
let is_even = fn (n: int) -> n % 2 == 0;
let fortytwo = fn () -> 42;
let greet = fn (name: str) -> "hello, " ++ name;
let _ = print "init";
()
MERE

"$MERE" -c --lib "$TMP/demo.mere" > "$TMP/demo.c" 2>"$TMP/demo.err" \
  || { echo "FAIL lib_check: mere -c --lib refused the demo"; cat "$TMP/demo.err"; exit 1; }

# 1. builds as a shared object; and no main was emitted
grep -q 'int main(' "$TMP/demo.c" && {
  echo "FAIL lib_check: --lib output still contains int main("; exit 1; }
"$CC" -O1 -w -fPIC -shared "$TMP/demo.c" -o "$TMP/demo.so" 2>"$TMP/cc.err" \
  || { echo "FAIL lib_check: shared build failed"; cat "$TMP/cc.err"; exit 1; }

# 2. the exported symbol set, exactly. `nm -gU` on macOS / `nm -g
#    --defined-only` elsewhere; macOS prefixes a `_`, so strip one.
if nm -gU "$TMP/demo.so" >/dev/null 2>&1; then
  syms="$(nm -gU "$TMP/demo.so" | awk '{print $3}' | sed 's/^_//' | sort)"
else
  syms="$(nm -g --defined-only "$TMP/demo.so" | awk '{print $3}' | sed 's/^_//' | sort)"
fi
# Linux .so files usually define a few link-editor symbols (__bss_start,
# _edata, _end, _fini, _init...) that no source line asked for; ignore them.
syms="$(echo "$syms" | grep -v '^_' | grep -v '^$' || true)"
expected="add2
fortytwo
is_even
scale"
expected_full="$(printf 'mere_lib_free\nmere_lib_init\nmere_lib_shutdown\n'; echo "$expected" | sed 's/^/mere_demo_/')"
expected_full="$(echo "$expected_full" | sort)"
[ "$syms" = "$expected_full" ] || {
  echo "FAIL lib_check: exported symbols differ from the boundary"
  echo "--- expected:"; echo "$expected_full"
  echo "--- got:"; echo "$syms"
  exit 1; }

# 3. a host calls the boundary; interp computes the same values
cat > "$TMP/host.c" <<'C'
#include <stdio.h>
typedef struct { const unsigned char* ptr; long long len; } mere_buf;
typedef enum { MERE_OK = 0, MERE_FAIL = 1 } mere_status;
mere_status mere_demo_add2(long long, long long, long long* out, mere_buf* err);
mere_status mere_demo_scale(double, double, double* out, mere_buf* err);
mere_status mere_demo_is_even(long long, int* out, mere_buf* err);
mere_status mere_demo_fortytwo(long long* out, mere_buf* err);
void mere_lib_shutdown(void);
int main(void) {
  long long s; double d; int b; long long f;
  if (mere_demo_add2(3, 4, &s, 0) != MERE_OK) return 1;
  if (mere_demo_add2(s, 10, &s, 0) != MERE_OK) return 1;  /* init must not re-run */
  if (mere_demo_scale(2.5, 4.0, &d, 0) != MERE_OK) return 1;
  if (mere_demo_is_even(10, &b, 0) != MERE_OK) return 1;
  if (mere_demo_fortytwo(&f, 0) != MERE_OK) return 1;
  printf("%lld %g %d %lld\n", s, d, b, f);
  mere_lib_shutdown();
  return 0;
}
C
"$CC" -O1 "$TMP/host.c" "$TMP/demo.so" -o "$TMP/host" 2>"$TMP/link.err" \
  || { echo "FAIL lib_check: host link failed"; cat "$TMP/link.err"; exit 1; }
got="$("$TMP/host")"
# Known values, written down rather than recomputed: backend agreement is
# ctest/parity's job — this gate's subject is the boundary, and its expected
# output must not depend on the very compiler under test.
want="init
17 10 1 42"
[ "$got" = "$want" ] || {
  echo "FAIL lib_check: host output differs from interp"
  echo "--- want: $want"
  echo "--- got:  $got"
  exit 1; }

# 4. the manifest is honest about what it skipped
grep -q 'greet -- str / bytes marshalling is a later slice' "$TMP/demo.c" || {
  echo "FAIL lib_check: manifest does not name the skipped str export"; exit 1; }

echo "lib_check: ok (boundary symbols exact, host matches interp, init ran once)"
