#!/bin/sh
# scripts/region_deps_check.sh — a container's private arena goes with its region.
#
# v0.1.688. map_compact, map_recycle, vec_compact and vec_recycle give a
# container an arena of its own. The container's struct stays in the region it
# was made in, and is freed with that region's blocks; the arena was freed with
# nothing. 8,000 maps compacted inside `region R { }` left 480 MB behind R. An
# arena is now tied to the region its container's struct lives in, and retired
# when that region's life ends (handed on with it when the region is kept).
#
# WHAT IS CHECKED: test/region_deps/maps compacts a thousand maps holding
# 300 KB each inside a region and leaves it, then says "freed" and waits. Its
# resident size at that moment is read from outside (ps): under 64 MiB. The
# values are large enough to be mapped by the runtime on macOS (16 KB and up)
# and by glibc on Linux (the runtime fixes its threshold at 64 KiB -- see
# block_return_check.sh), so a freed arena leaves both and a leaked one stays
# on both: 6 MB and 314 MB on macOS, 5 MB and 308 MB on Linux.
#
# --poison: the release no longer drops the arenas, and the resident size must
# go over the cap.
#
# Usage:
#   sh scripts/region_deps_check.sh            # check
#   sh scripts/region_deps_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "region_deps: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "region_deps: no C compiler -- cannot answer"; exit 2; }
command -v ps >/dev/null 2>&1 || { echo "region_deps: no ps -- cannot answer"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CAP_MB=64

# $1 = sed expression applied to the emitted C ("" for none) -> resident MB after the region, or why not
resident_after_region() {
  "$MERE" -c "$ROOT/test/region_deps/maps.mere" > "$T/a.c" 2> "$T/err" || { echo "emit: $(head -1 "$T/err")"; return 1; }
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
    i=$((i + 1)); [ "$i" -gt 2400 ] && { kill "$pid"; echo "never said freed"; return 1; }
    sleep 0.05
  done
  r=$(ps -o rss= -p "$pid" | awk '{print int($1 / 1024)}')
  wait "$pid"
  grep -q '^1000$' "$T/out" || { echo "wrong output: $(head -2 "$T/out" | tr '\n' ' ')"; return 1; }
  echo "$r"
}

if [ "${1:-}" = --poison ]; then
  r=$(resident_after_region 's/^  if (r->deps) __lang_region_deps_drop(r);$/  ;/') || { echo "region_deps: POISON could not run: $r"; exit 1; }
  if [ "$r" -ge "$CAP_MB" ]; then echo "region_deps: poison ok -- with the arenas left behind, $r MB stays resident after the region"; exit 0; fi
  echo "region_deps: POISON still under the cap with the arenas left behind ($r MB)"; exit 1
fi
r=$(resident_after_region "") || { echo "region_deps: FAIL $r"; exit 1; }
if [ "$r" -lt "$CAP_MB" ]; then echo "region_deps: ok -- $r MB resident after a region of 1,000 compacted maps was left"; exit 0; fi
echo "region_deps: FAIL -- $r MB resident after a region of 1,000 compacted maps was left (cap $CAP_MB)"; exit 1
