#!/bin/sh
# scripts/region_sites_check.sh -- `mere -c --region-sites` names the source line
# whose containers filled the default region, and changes nothing else.
#
# WHY. The default region is never given back. mgit's was 11.5 GB, and finding
# that 8.3 GB of it was one line -- an inflate window a function made and did not
# return, so it was in no type -- took 23 rebuilds, one allocation site at a time
# moved elsewhere. The meter now says it in one run (v0.1.570).
#
# What is held:
#   1. the program's output is the interpreter's, with the flag and without it
#   2. the `default:` total is the same with the flag and without it -- each line's
#      region forwards to the default one, so where memory lives has not moved
#   3. the top line is test/regionsites/window.mere:7 (the window), and it carries
#      at least 200 windows of 64 KiB
#
# --poison: a line that is not charged for what it allocates (3 goes red), and a
# line's region that keeps its own memory instead of forwarding (2 goes red).
#
# Usage: sh scripts/region_sites_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "region_sites: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC="$ROOT/test/regionsites/window.mere"
MODE="${1:-}"

# $1 = extra flag ("" or --region-sites), $2 = sed expression or "" -> $T/bin
build() {
  "$MERE" -c $1 "$SRC" > "$T/g.c" 2>"$T/emit.err" || { echo "EMITFAIL $(head -1 "$T/emit.err")"; return 1; }
  if [ -n "$2" ]; then
    sed "$2" "$T/g.c" > "$T/p.c"
    if cmp -s "$T/p.c" "$T/g.c"; then echo "SEDNOMATCH"; return 1; fi
    mv "$T/p.c" "$T/g.c"
  fi
  "$CC" -O2 -w -o "$T/bin" "$T/g.c" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(head -1 "$T/cc.err")"; return 1; }
}

# -> prints "ok" or why not
judge() {  # $1 = sed expression for the --region-sites build
  if ! why=$(build "" ""); then echo "$why"; return; fi
  plain_out=$(MERE_REGION_STATS=1 "$T/bin" 2>"$T/plain.err")
  plain_total=$(sed -n 's/^region-stats default: .*alloc_total=\([0-9]*\).*/\1/p' "$T/plain.err")
  if ! why=$(build --region-sites "$1"); then echo "$why"; return; fi
  sites_out=$(MERE_REGION_STATS=1 "$T/bin" 2>"$T/sites.err")
  sites_total=$(sed -n 's/^region-stats default: .*alloc_total=\([0-9]*\).*/\1/p' "$T/sites.err")
  top=$(sed -n 's/^region-stats default-site \(.*\): alloc_total=\([0-9]*\)$/\1 \2/p' "$T/sites.err" | head -1)
  [ "$plain_out" = "$want" ] || { echo "the output without the flag is [$plain_out], wanted [$want]"; return; }
  [ "$sites_out" = "$want" ] || { echo "the output with the flag is [$sites_out], wanted [$want]"; return; }
  [ -n "$plain_total" ] && [ "$plain_total" = "$sites_total" ] \
    || { echo "the default region's total moved: $plain_total without the flag, $sites_total with it"; return; }
  line=${top% *}; bytes=${top##* }
  case "$line" in
    *window.mere:7) ;;
    *) echo "the top line is [$top], wanted window.mere:7"; return ;;
  esac
  [ "$bytes" -ge $((200 * 65536)) ] || { echo "window.mere:7 carries $bytes bytes, fewer than 200 windows"; return; }
  echo ok
}

want=$("$MERE" "$SRC" 2>&1)
got=$(judge "")
if [ "$got" != ok ]; then echo "  FAIL  $got"; echo "region_sites: FAILED"; exit 1; fi
echo "  ok    the window's line is named, and the output and the default total are unchanged"

if [ "$MODE" = --poison ]; then
  pfail=0
  # program | what it undoes | sed
  for p in 'a line is not charged for what it allocates|s/if (r \&\& r->fwd) { __lang_dsite_charge(r, (n + 7) \& ~((size_t)7)); r = __lang_region_live(r); }/if (r \&\& r->fwd) { r = __lang_region_live(r); }/' \
           'a line keeps its own memory|s/st->site = s->name; st->fwd = \&__lang_default_region;/st->site = s->name; st->fwd = NULL;/'; do
    what=${p%%|*}; expr=${p#*|}
    got=$(judge "$expr")
    case "$got" in
      ok) echo "  FAIL  POISON ($what): still green -- the gate does not witness it"; pfail=1 ;;
      SEDNOMATCH|EMITFAIL*|CCFAIL*) echo "  FAIL  POISON ($what): $got"; pfail=1 ;;
      *) echo "  ok    POISON ($what): goes red -- $got" ;;
    esac
  done
  [ "$pfail" = 0 ] || { echo "region_sites --poison: FAILED"; exit 1; }
  echo "region_sites --poison: ok (the gate can go red)"
  exit 0
fi
echo "region_sites: ok"
