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
let revb = fn (b: bytes) ->
  let n = bytes_len b in
  let out = bytebuf_new 0 in
  let rec go = fn (i: int) ->
    if i == n then () else let _ = bytebuf_push out (bytes_get b (n - 1 - i)) in go (i + 1) in
  let _ = go 0 in
  bytes_of_bytebuf out;
let pick = fn (f: int -> int) -> f 1;
let boom = fn (flag: int) -> if flag == 1 then fail "boom says no" else flag;
let _ = print "init";
()
MERE

"$MERE" --header "$TMP/demo.mere" > "$TMP/demo.h" 2>"$TMP/hdr.err" \
  || { echo "FAIL lib_check: mere --header refused the demo"; cat "$TMP/hdr.err"; exit 1; }

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
boom
fortytwo
greet
is_even
revb
scale"
expected_full="$(printf 'mere_lib_free\nmere_lib_init\nmere_lib_shutdown\n'; echo "$expected" | sed 's/^/mere_demo_/')"
expected_full="$(echo "$expected_full" | sort)"
[ "$syms" = "$expected_full" ] || {
  echo "FAIL lib_check: exported symbols differ from the boundary"
  echo "--- expected:"; echo "$expected_full"
  echo "--- got:"; echo "$syms"
  exit 1; }

# 3. a host calls the boundary; interp computes the same values
# the host compiles against the GENERATED header -- that is the header's test
cat > "$TMP/host.c" <<'C'
#include <stdio.h>
#include "demo.h"
int main(void) {
  long long s; double d; int b; long long f;
  if (mere_demo_add2(3, 4, &s, 0) != MERE_OK) return 1;
  if (mere_demo_add2(s, 10, &s, 0) != MERE_OK) return 1;  /* init must not re-run */
  if (mere_demo_scale(2.5, 4.0, &d, 0) != MERE_OK) return 1;
  if (mere_demo_is_even(10, &b, 0) != MERE_OK) return 1;
  if (mere_demo_fortytwo(&f, 0) != MERE_OK) return 1;
  printf("%lld %g %d %lld\n", s, d, b, f);

  /* str out is a malloc'd copy with a courtesy NUL past .len */
  mere_buf name = { (const unsigned char*)"world", 5 };
  mere_buf out, err;
  if (mere_demo_greet(name, &out, &err) != MERE_OK) return 1;
  printf("%.*s nul=%d\n", (int)out.len, out.ptr, out.ptr[out.len]);
  mere_lib_free((void*)out.ptr);

  /* bytes round-trip with embedded NULs -- a boundary that only carries C
     strings would silently truncate this */
  unsigned char raw[5] = { 0x01, 0x00, 0xff, 0x02, 0x00 };
  mere_buf bin = { raw, 5 };
  if (mere_demo_revb(bin, &out, &err) != MERE_OK) return 1;
  printf("revb=");
  { long long i; for (i = 0; i < out.len; i++) printf("%02x", out.ptr[i]); }
  printf("\n");
  mere_lib_free((void*)out.ptr);

  /* a fail comes back as a status + message, not as the host's death;
     and the library keeps working after its own failure */
  { long long r; mere_buf e2;
    if (mere_demo_boom(1, &r, &e2) != MERE_FAIL) return 1;
    printf("%.*s\n", (int)e2.len, e2.ptr);
    mere_lib_free((void*)e2.ptr);
    if (mere_demo_boom(7, &r, &e2) != MERE_OK) return 1;
    printf("after=%lld\n", r); }

  mere_lib_shutdown();
  return 0;
}
C
"$CC" -O1 -I"$TMP" "$TMP/host.c" "$TMP/demo.so" -o "$TMP/host" 2>"$TMP/link.err" \
  || { echo "FAIL lib_check: host link failed"; cat "$TMP/link.err"; exit 1; }
got="$("$TMP/host")"
# Known values, written down rather than recomputed: backend agreement is
# ctest/parity's job — this gate's subject is the boundary, and its expected
# output must not depend on the very compiler under test.
want="init
17 10 1 42
hello, world nul=0
revb=0002ff0001
fail: boom says no
after=7"
[ "$got" = "$want" ] || {
  echo "FAIL lib_check: host output differs from interp"
  echo "--- want: $want"
  echo "--- got:  $got"
  exit 1; }

# 4. the manifest is honest about what it skipped
grep -q 'pick -- type not representable at the C boundary' "$TMP/demo.c" || {
  echo "FAIL lib_check: manifest does not name the skipped higher-order export"; exit 1; }

# ---- 5. memory contract: calls are transactions ----------------------------
# Each wrapper call runs in its own region; containers whose region erased to
# __heap follow the current region (v0.1.311), so the DEFAULT region must not
# grow with the number of calls. The check is two-sided: module init builds a
# map (so alloc_total > 0 proves the meter sees the subject), then two runs
# with different call counts must report the SAME default-region numbers --
# equal-and-positive is growth-free; zero would mean the meter broke.
cat > "$TMP/state.mere" <<'MERE'
let base = map_new ();
let seed =
  let rec go = fn (i: int) ->
    if i == 64 then () else let _ = map_set base i (i * i) in go (i + 1) in
  go 0;
let counts = map_new ();
let names = map_new ();
let bump = fn (k: int) ->
  let cur = if map_has counts k then map_get counts k else 0 in
  let _ = map_set counts k (cur + 1) in
  cur + 1;
let label = fn (k: int) -> fn (name: str) ->
  let _ = map_set names k (name ++ "!") in
  0;
let read_label = fn (k: int) ->
  if map_has names k then map_get names k else "(none)";
let churn = fn (n: int) ->
  let v = vec_new () in
  let m = map_new () in
  let rec go = fn (i: int) ->
    if i == n then ()
    else
      let _ = vec_push v (i * 2) in
      let _ = map_set m i (str_of_int i) in
      go (i + 1) in
  let _ = go 0 in
  vec_len v + map_len m;
MERE
"$MERE" -c --lib "$TMP/state.mere" > "$TMP/state.c" 2>"$TMP/state.err" \
  || { echo "FAIL lib_check: mere -c --lib refused the state lib"; cat "$TMP/state.err"; exit 1; }
"$CC" -O1 -w -fPIC -shared "$TMP/state.c" -o "$TMP/state.so" \
  || { echo "FAIL lib_check: state lib shared build failed"; exit 1; }

cat > "$TMP/hoststate.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { const unsigned char* ptr; long long len; } mere_buf;
typedef enum { MERE_OK = 0, MERE_FAIL = 1 } mere_status;
mere_status mere_state_bump(long long, long long* out, mere_buf* err);
mere_status mere_state_label(long long, mere_buf, long long* out, mere_buf* err);
mere_status mere_state_read_label(long long, mere_buf* out, mere_buf* err);
mere_status mere_state_churn(long long, long long* out, mere_buf* err);
void mere_lib_free(void* p);
void mere_lib_shutdown(void);
int main(int argc, char** argv) {
  long long n = argc > 1 ? atoll(argv[1]) : 1000, r;
  /* a call-local str stored into module state must survive the call's
     region AND the host reusing its buffer (copy-on-store, twice) */
  char scratch[8]; strcpy(scratch, "hello");
  mere_buf nm = { (const unsigned char*)scratch, 5 };
  if (mere_state_label(1, nm, &r, 0) != MERE_OK) return 1;
  memset(scratch, 'X', sizeof scratch);
  for (long long i = 0; i < n; i++) {
    if (mere_state_churn(24, &r, 0) != MERE_OK || r != 48) return 1;
    if (mere_state_bump(7, &r, 0) != MERE_OK) return 1;
  }
  mere_buf out, err;
  if (mere_state_read_label(1, &out, &err) != MERE_OK) return 1;
  printf("count=%lld label=%.*s\n", r, (int)out.len, out.ptr);
  mere_lib_free((void*)out.ptr);
  mere_lib_shutdown();
  return 0;
}
C
"$CC" -O1 "$TMP/hoststate.c" "$TMP/state.so" -o "$TMP/hoststate" \
  || { echo "FAIL lib_check: state host link failed"; exit 1; }

small="$(MERE_REGION_STATS=1 "$TMP/hoststate" 2000 2>&1)"
large="$(MERE_REGION_STATS=1 "$TMP/hoststate" 50000 2>&1)"
echo "$small" | grep -q "count=2000 label=hello!" || {
  echo "FAIL lib_check: module state wrong after 2000 calls"; echo "$small"; exit 1; }
echo "$large" | grep -q "count=50000 label=hello!" || {
  echo "FAIL lib_check: module state wrong after 50000 calls"; echo "$large"; exit 1; }
stat_small="$(echo "$small" | grep '^region-stats default:')"
stat_large="$(echo "$large" | grep '^region-stats default:')"
alloc_small="$(echo "$stat_small" | sed -n 's/.*alloc_total=\([0-9]*\).*/\1/p')"
[ -n "$stat_small" ] && [ -n "$stat_large" ] || {
  echo "FAIL lib_check: no region-stats line -- meter gone"; exit 1; }
[ "$alloc_small" -gt 0 ] || {
  echo "FAIL lib_check: default alloc_total is 0 -- the meter cannot see module init"; exit 1; }
[ "$stat_small" = "$stat_large" ] || {
  echo "FAIL lib_check: default region grew with the call count -- calls are not transactions"
  echo "--- 2000  calls: $stat_small"
  echo "--- 50000 calls: $stat_large"
  exit 1; }

# ---- 6. thread contract: concurrent calls from 8 host threads --------------
cat > "$TMP/hostmt.c" <<'C'
#include <stdio.h>
#include <pthread.h>
typedef struct { const unsigned char* ptr; long long len; } mere_buf;
typedef enum { MERE_OK = 0, MERE_FAIL = 1 } mere_status;
mere_status mere_demo_add2(long long, long long, long long* out, mere_buf* err);
mere_status mere_demo_greet(mere_buf, mere_buf* out, mere_buf* err);
mere_status mere_demo_boom(long long, long long* out, mere_buf* err);
void mere_lib_free(void* p);
static void* worker(void* arg) {
  (void)arg;
  long long r; mere_buf out, err;
  mere_buf name = { (const unsigned char*)"mt", 2 };
  for (int i = 0; i < 4000; i++) {
    if (mere_demo_add2(i, i, &r, 0) != MERE_OK || r != 2 * i) return (void*)1;
    if (mere_demo_greet(name, &out, 0) != MERE_OK || out.len != 9) return (void*)1;
    mere_lib_free((void*)out.ptr);
    if (mere_demo_boom(1, &r, &err) != MERE_FAIL) return (void*)1;  /* per-thread jmpbuf */
    mere_lib_free((void*)err.ptr);
  }
  return NULL;
}
int main(void) {
  pthread_t t[8]; int bad = 0;
  for (int i = 0; i < 8; i++) pthread_create(&t[i], NULL, worker, NULL);
  for (int i = 0; i < 8; i++) { void* rv; pthread_join(t[i], &rv); if (rv) bad++; }
  printf("mt bad=%d\n", bad);
  return bad ? 1 : 0;
}
C
"$CC" -O1 "$TMP/hostmt.c" "$TMP/demo.so" -o "$TMP/hostmt" -lpthread \
  || { echo "FAIL lib_check: mt host link failed"; exit 1; }
"$TMP/hostmt" | grep -q "mt bad=0" || {
  echo "FAIL lib_check: concurrent calls returned wrong values"; exit 1; }

echo "lib_check: ok (boundary exact, header-built host, str/bytes round-trip, fail -> status, calls are transactions, 8-thread clean)"
