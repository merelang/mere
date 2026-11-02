#!/bin/sh
# scripts/block_return_check.sh — a freed region's blocks go back to the system.
#
# v0.1.686. On macOS the C runtime took every region block from malloc, and
# malloc (macOS 26, by default) keeps what is freed in both the resident size
# and the footprint: a program that compacts or recycles arenas over and over
# (mere-ruby with a thousand suspended fibers under a collection every 50
# safepoints) grew without bound, 2.6 GB of empty small regions, and
# malloc_zone_pressure_relief answered 0 bytes. A block of 16 KB or more is
# now mapped and unmapped.
#
# WHAT IS CHECKED: test/block_return/freed grows a region to about 400 MB and
# leaves it, then says "freed" and waits. Its resident size at that moment is
# read from outside (ps): under 64 MiB. Under malloc it was 841 MB.
#
# Linux keeps malloc (glibc maps large blocks and trims its heap itself, and a
# mapping per block counts toward vm.max_map_count), so there this gate is
# optional and not run: exit 3.
#
# --poison: the emitted C allocates and frees its blocks through malloc again,
# and the resident size must go over the cap.
#
# Usage:
#   sh scripts/block_return_check.sh            # check
#   sh scripts/block_return_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ "$(uname -s)" = Darwin ] || { echo "block_return: macOS only -- Linux keeps malloc for region blocks"; exit 3; }
[ -x "$MERE" ] || { echo "block_return: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "block_return: no C compiler -- cannot answer"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CAP_MB=64

# $1 = sed expression applied to the emitted C ("" for none) -> resident MB after the free, or why not
resident_after_free() {
  "$MERE" -c "$ROOT/test/block_return/freed.mere" > "$T/a.c" 2> "$T/err" || { echo "emit: $(head -1 "$T/err")"; return 1; }
  if [ -n "$1" ]; then
    sed "$1" "$T/a.c" > "$T/b.c"
    cmp -s "$T/a.c" "$T/b.c" && { echo "the runtime no longer has the shape this poison edits"; return 1; }
    mv "$T/b.c" "$T/a.c"
  fi
  "$CC" -O2 -w "$T/a.c" -o "$T/bin" -lm -lpthread 2> "$T/err" || { echo "cc: $(head -1 "$T/err")"; return 1; }
  "$T/bin" > "$T/out" 2>&1 &
  pid=$!
  i=0
  while ! grep -q freed "$T/out" 2>/dev/null; do
    kill -0 "$pid" 2>/dev/null || { echo "exited before it said freed: $(head -2 "$T/out" | tr '\n' ' ')"; return 1; }
    i=$((i + 1)); [ "$i" -gt 1200 ] && { kill "$pid"; echo "never said freed"; return 1; }
    sleep 0.05
  done
  r=$(ps -o rss= -p "$pid" | awk '{print int($1 / 1024)}')
  wait "$pid"
  grep -q '^8000$' "$T/out" || { echo "wrong output: $(head -2 "$T/out" | tr '\n' ' ')"; return 1; }
  echo "$r"
}

if [ "${1:-}" = --poison ]; then
  r=$(resident_after_free 's/^  if (total < __LANG_BLK_MAP_MIN) return malloc(total);$/  return malloc(total);/; s/^  if (total < __LANG_BLK_MAP_MIN) free(p); else munmap(p, total);$/  free(p);/; s/^  if (old_total < __LANG_BLK_MAP_MIN \&\& new_total < __LANG_BLK_MAP_MIN) return realloc(p, new_total);$/  return realloc(p, new_total);/') || { echo "block_return: POISON could not run: $r"; exit 1; }
  if [ "$r" -ge "$CAP_MB" ]; then echo "block_return: poison ok -- with malloc blocks, $r MB stays resident after the free"; exit 0; fi
  echo "block_return: POISON still under the cap with malloc blocks ($r MB)"; exit 1
fi
r=$(resident_after_free "") || { echo "block_return: FAIL $r"; exit 1; }
if [ "$r" -lt "$CAP_MB" ]; then echo "block_return: ok -- $r MB resident after a 400 MB region was freed"; exit 0; fi
echo "block_return: FAIL -- $r MB resident after a 400 MB region was freed (cap $CAP_MB)"; exit 1
