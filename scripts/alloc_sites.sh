#!/bin/sh
# scripts/alloc_sites.sh — WHICH SITES fill the arenas of a compiled program?
#
#   mere -c prog.mere > prog.c
#   sh scripts/alloc_sites.sh prog.c [args...]
#
# MERE_REGION_STATS says HOW MUCH a program allocated. This says WHERE FROM: it
# builds a copy of the generated C with a table inside the region allocator that
# records the return address of every allocation (and its caller, and its
# caller's caller), runs the program, and prints three tables of
# "function  calls  MiB  %", biggest first.
#
# Each level answers a different question and none answers the next: level 0
# names the allocating helper (`__lang_str_alloc`, `__mcopy_<T>`), level 1 names
# the runtime that called it (`mere_map_str_int_set`, `__lang_str_concat`), and
# level 2 is usually the first PROGRAM function -- the one a fix has to be
# written against. Frame pointers are kept so walking two frames up is defined.
#
# Why return addresses and not reasoning: every one of the json parser's three
# footprint fixes (v0.1.322-324) was found by this table and not by the
# argument about where the bytes ought to be -- the top site was a different
# function each time. Attribute first; the memory-attribution notes call this
# step 4 of the ladder.
#
# Options (environment):
#   ALLOC_SITES_DEFAULT_ONLY=1   count default-region allocations only (what a
#                                program keeps for its whole life), not named
#                                `region R { }` arenas
#   ALLOC_SITES_TOP=N            rows per table (default 40)
#
# Symbolization: `atos` on macOS, `addr2line` on Linux; raw addresses if neither
# is present. The tool is a probe, not a gate -- its numbers are exact for one
# run of one binary, and it is for pointing at the next thing to read.
set -u
[ $# -ge 1 ] || { echo "usage: alloc_sites.sh prog.c [args...]" >&2; exit 2; }
src="$1"; shift
[ -f "$src" ] || { echo "alloc_sites: $src not found (generate it with: mere -c prog.mere > prog.c)" >&2; exit 2; }
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "alloc_sites: no C compiler" >&2; exit 2; }
top="${ALLOC_SITES_TOP:-40}"
default_only="${ALLOC_SITES_DEFAULT_ONLY:-0}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/pre.c" <<'PRE'
#include <dlfcn.h>
#define __AS_N 65536
typedef struct { void* a; unsigned long long c, b; } __as_row;
static __as_row __as0[__AS_N], __as1[__AS_N], __as2[__AS_N];
static void __as_note_in(void* ra, unsigned long long n, __as_row* t) {
  unsigned long long h = ((unsigned long long)ra) >> 2;
  h = (h ^ (h >> 16)) & (__AS_N - 1);
  for (unsigned long long i = 0; i < __AS_N; i++) {
    unsigned long long k = (h + i) & (__AS_N - 1);
    if (t[k].a == ra) { t[k].c++; t[k].b += n; return; }
    if (t[k].a == 0)  { t[k].a = ra; t[k].c = 1; t[k].b = n; return; }
  }
}
static void __as_note(void* ra0, void* ra1, void* ra2, unsigned long long n) {
  __as_note_in(ra0, n, __as0);
  __as_note_in(ra1, n, __as1);
  __as_note_in(ra2, n, __as2);
}
static void __as_dump(const char* tag, __as_row* t, int top) {
  for (int rank = 0; rank < top; rank++) {
    unsigned long long best = 0; int bi = -1;
    for (int i = 0; i < __AS_N; i++)
      if (t[i].a && t[i].b > best) { best = t[i].b; bi = i; }
    if (bi < 0) break;
    fprintf(stderr, "%s %p %llu %llu\n", tag, t[bi].a, t[bi].c, t[bi].b);
    t[bi].a = 0; t[bi].b = 0;
  }
}
static void __attribute__((destructor)) __as_report(void) {
  Dl_info di;
  void* base = 0;
  if (dladdr((void*)&__as_dump, &di)) base = di.dli_fbase;
  const char* t = getenv("ALLOC_SITES_TOP");
  int top = t ? atoi(t) : 40;
  fprintf(stderr, "ALLOCSITES base=%p\n", base);
  __as_dump("SITE", __as0, top);
  __as_dump("UPSITE", __as1, top);
  __as_dump("UP2SITE", __as2, top);
}
PRE

# The splice is done on BYTES, not lines: a generated C file may embed data
# that is not valid text (mere-ruby's carries Ruby sources with NULs and
# 397 KB lines), and awk over it dropped 11 bytes far from the patch.
python3 - "$src" "$tmp/pre.c" "$tmp/probe.c" "$default_only" <<'PYEOF'
import sys
src, pre, dst, default_only = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
b = open(src, "rb").read()
p = open(pre, "rb").read()
key = b"static void __lang_region_add_block("
i = b.find(key)
if i < 0:
    sys.exit("alloc_sites: could not find the region allocator in the generated C")
b = b[:i] + p + b[i:]
sig = b"static void* __lang_region_alloc(__lang_region* r, size_t n) {"
if sig not in b:
    sys.exit("alloc_sites: the allocator's signature has changed; update this script")
# out of line, so the return address names the caller
b = b.replace(sig, b"static void* __attribute__((noinline)) __lang_region_alloc(__lang_region* r, size_t n) {", 1)
anchor = b"size_t aligned = (n + 7) & ~((size_t)7);"
i = b.find(anchor)
if i < 0:
    sys.exit("alloc_sites: the allocator's rounding line has changed; update this script")
j = b.index(b"\n", i)
cond = b"if (shared) " if default_only else b""
b = b[:j] + b"\n  " + cond + (b"__as_note(__builtin_return_address(0),"
             b" __builtin_return_address(1), __builtin_return_address(2), aligned);") + b[j:]
open(dst, "wb").write(b)
PYEOF
[ $? -eq 0 ] || exit 1

ldflags=""
case "$(uname -s)" in
  Darwin) ldflags="-Wl,-no_deduplicate -Wl,-stack_size,0x20000000" ;;
esac
# -fno-omit-frame-pointer so __builtin_return_address(1) walks a real chain;
# -no_deduplicate so the linker does not fold same-bodied functions into one
# <deduplicated_symbol> that atos cannot name.
# shellcheck disable=SC2086
"$CC" -O2 -w -fno-omit-frame-pointer $ldflags -ldl "$tmp/probe.c" -o "$tmp/prog" 2> "$tmp/cc.err" || {
  echo "alloc_sites: build failed:"; head -5 "$tmp/cc.err"; exit 1; }

"$tmp/prog" "$@" > /dev/null 2> "$tmp/err" || true
grep -E '^(ALLOCSITES|SITE|UPSITE|UP2SITE) ' "$tmp/err" > "$tmp/sites" || {
  echo "alloc_sites: no table on stderr -- did the program crash before exit?"; tail -5 "$tmp/err"; exit 1; }

base=$(sed -n 's/^ALLOCSITES base=\(.*\)/\1/p' "$tmp/sites")
mib() { awk -v x="$1" 'BEGIN{printf "%.1f", x/1048576}'; }

symbolize() { # stdin: addresses, one per line -> names, one per line
  if command -v atos >/dev/null 2>&1 && [ -n "$base" ] && [ "$base" != "0x0" ]; then
    # shellcheck disable=SC2046
    atos -o "$tmp/prog" -l "$base" $(cat) 2>/dev/null
  elif command -v addr2line >/dev/null 2>&1 && [ -n "$base" ]; then
    while read -r a; do
      rel=$(python3 -c "print(hex(int('$a',16)-int('$base',16)))")
      addr2line -f -C -e "$tmp/prog" "$rel" 2>/dev/null | head -1
    done
  else
    cat
  fi
}

show_table() { # $1 = tag, $2 = heading
  tag="$1"; heading="$2"
  total=$(awk -v t="$tag" '$1 == t { s += $4 } END { print s + 0 }' "$tmp/sites")
  awk -v t="$tag" '$1 == t { print $2 }' "$tmp/sites" > "$tmp/addrs"
  [ -s "$tmp/addrs" ] || return 0
  symbolize < "$tmp/addrs" > "$tmp/names"
  [ "$(wc -l < "$tmp/names")" -eq "$(wc -l < "$tmp/addrs")" ] || cp "$tmp/addrs" "$tmp/names"
  printf '\n%-64s %12s %10s %6s\n' "$heading" calls MiB "%"
  awk -v t="$tag" '$1 == t { print $3, $4 }' "$tmp/sites" > "$tmp/nums"
  paste "$tmp/nums" "$tmp/names" | while read -r calls bytes name; do
    pct=$(awk -v b="$bytes" -v t="$total" 'BEGIN{ if (t > 0) printf "%.1f", 100*b/t; else print "0" }')
    printf '%-64.64s %12s %10s %6s\n' "$name" "$calls" "$(mib "$bytes")" "$pct"
  done
  printf 'listed rows total: %s MiB\n' "$(mib "$total")"
}

if [ "$default_only" = "1" ]; then
  echo "alloc_sites: default-region allocations only"
else
  echo "alloc_sites: every arena (default and named regions)"
fi
show_table SITE    "site (the helper that called region_alloc)"
show_table UPSITE  "one level up (the runtime that called the helper)"
show_table UP2SITE "two levels up (usually the program's function)"
