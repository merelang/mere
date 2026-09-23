#!/bin/sh
# scripts/fdio_check.sh — the fd_* externs: an open file, checked against
# values the probe sets itself.
#
# WHY THESE ARE A RUNTIME AND NOT AN `extern` A PROGRAM WRITES. read(2),
# write(2) and close(2) ARE in <unistd.h> and could be declared by hand.
# open(2) cannot: it lives in <fcntl.h>, which an emitted program does not
# include, and its flags are platform constants a caller would have to guess.
# lseek is the same shape -- off_t is a typedef and SEEK_SET/CUR/END are
# constants of that kind. Splitting the family across two mechanisms would
# leave half the contract in the caller's hands, so all eight are here.
#
# TWO CONTRACTS THE RUNTIME DEFINES, and both are exercised below: the MODE is
# a string as fopen takes it (r/w/a, optional +, optional trailing b that is
# accepted and ignored), and the WHENCE is 0 set / 1 cur / 2 end.
#
# EVERY EXPECTATION IS A VALUE THE PROBE SET. It writes and reads back, seeks
# and reads from where it landed, appends and measures. Nothing here is a
# snapshot of one machine, so the gate is the same on any POSIX host.
#
# ⚠ THIS GATE HAS ALREADY EARNED ITS KEEP, TWICE, AND BOTH WERE THE PROBE'S
#   FAULT RATHER THAN THE RUNTIME'S:
#     1. A poison test that SWAPPED SEEK_CUR and SEEK_END moved no row. The
#        probe seeked to the end and then -5 from CUR, and at that moment the
#        position WAS the end, so the two readings answered the same number.
#        Every seek is taken from a position that is neither 0 nor the end now.
#     2. A poison test that dropped O_TRUNC from "w" passed on a clean machine
#        and failed on a dirty one: the probe opened "w" over whatever the last
#        run left behind, so it was reading the previous run instead of its own
#        setup. It lays down longer content itself first now.
#   Four poisons are caught as of v0.1.522: swapped whence, "a" opening with
#   O_TRUNC, "w" without it, fd_read off by one, and dup not sharing the offset.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "fdio_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "fdio_check: no C compiler" >&2; exit 0; }

TMP="$(mktemp -d)"
# the probe writes this fixed path, and it must not inherit one: see the note
# above about "w" reading the previous run.
PROBE_FILE=/tmp/mere_fdio_probe
trap 'rm -rf "$TMP" "$PROBE_FILE"' EXIT
rm -f "$PROBE_FILE"

"$MERE" -c "$ROOT/test/fdio/fdio_probe.mere" > "$TMP/p.c" 2>"$TMP/p.err" \
  || { echo "FAIL fdio: mere -c refused the probe"; cat "$TMP/p.err"; exit 1; }
"$CC" -O1 -w "$TMP/p.c" -o "$TMP/p" 2>"$TMP/cc.err" \
  || { echo "FAIL fdio: C compile failed"; cat "$TMP/cc.err"; exit 1; }

rm -f "$PROBE_FILE"
sh "$ROOT/scripts/bounded.sh" 30 "$TMP/p" > "$TMP/got" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL fdio: probe exited $rc"; cat "$TMP/got"; exit 1; }

# The probe prints one line per check. A FAIL line carries got= and want=, so
# the transcript is compared AS A WHOLE rather than grepped: a row that stops
# being printed at all is a failure too, and grep would not see it.
cat > "$TMP/want" <<'W'
open w ok
write ok
sync ok
close w ok
w truncated ok
read count ok
read bytes ok
seek set ok
read after seek ok
seek set again ok
seek cur ok
seek end ok
read after seek end ok
read at eof ok
seek to start ok
dup ok
dup shares the offset ok
close dup ok
close r ok
append ok
mode rb accepted ok
unknown mode ok
missing file ok
read a closed fd ok
close twice ok
negative fd ok
whence out of range ok
isatty on a file ok
pipe ok
pipe ends differ ok
pipe write ok
pipe read ok
pipe is not a tty ok
pipe cannot seek ok
close pipe read ok
close pipe write ok
W

if diff -u "$TMP/want" "$TMP/got" > "$TMP/d" 2>&1; then
  echo "fdio: 36/36 ok"
else
  echo "FAIL fdio: the transcript differs"
  cat "$TMP/d"
  exit 1
fi
