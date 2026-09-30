#!/bin/sh
# scripts/proclimit_check.sh — the proc_* limit and priority externs and
# file_flock, checked against values the probe sets itself.
#
# WHY THESE ARE A RUNTIME AND NOT AN `extern` A PROGRAM WRITES. Each is behind
# a different wall. getrlimit/setrlimit move the limits through a
# `struct rlimit *`, which no extern can spell. getpriority/setpriority take an
# id_t, an unsigned typedef: <sys/resource.h> IS in every emitted program
# (through <stdlib.h> and <sys/wait.h>), so the prototype Mere writes meets the
# real one and is a "conflicting types" error. flock(2) is in <sys/file.h>,
# which an emitted program does not include.
#
# THREE CONTRACTS THE RUNTIME DEFINES, and all three are exercised below,
# because the platform's own numbers differ where it matters: RLIMIT_NOFILE is
# 8 on macOS and 7 on Linux, RLIM_INFINITY is 2^63-1 on one and 2^64-1 on the
# other, and EWOULDBLOCK is 35 and 11.
#   a resource is asked for BY NAME, and a limit of -1 is RLIM_INFINITY in both
#   directions; the priority selector is 0 process / 1 group / 2 user; the lock
#   bits are 1 shared / 2 exclusive / 4 non-blocking / 8 unlock, and a lock
#   refused under LOCK_NB answers 1 rather than leaving the caller to compare
#   errno with a number that is not the same on the two hosts.
#
# EVERY EXPECTATION IS A VALUE THE PROBE SET OR A REFUSAL IT PROVOKED. It lowers
# a soft limit and reads it back, restores it and reads that back, raises its
# own nice value and reads it, locks a file through one open and is refused
# through another. No limit is compared with a number written in this file, so
# the gate is the same on any POSIX host. The errno numbers that ARE written
# down (EINVAL 22, ESRCH 3, EBADF 9) are the same on macOS, Linux and the BSDs.
#
# ⚠ THE PROBE BROKE ITSELF ON ITS FIRST RUN, and the way is worth keeping. A
#   "soft above hard" row asked for the current hard limit plus one; NOFILE's
#   hard limit is unlimited on macOS, which crosses as -1, so it asked for a
#   soft limit of 0 descriptors -- and got it. Every open after that row
#   failed. A sentinel is a number, and arithmetic on it is a bug; the row
#   names both of its numbers now.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "proclimit_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "proclimit_check: no C compiler" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" /tmp/mere_proclimit_probe' EXIT

"$MERE" -c "$ROOT/test/proclimit/proclimit_probe.mere" > "$TMP/p.c" 2>"$TMP/p.err" \
  || { echo "FAIL proclimit: mere -c refused the probe"; cat "$TMP/p.err"; exit 1; }
"$CC" -O1 -w "$TMP/p.c" -o "$TMP/p" 2>"$TMP/cc.err" \
  || { echo "FAIL proclimit: C compile failed"; cat "$TMP/cc.err"; exit 1; }

sh "$ROOT/scripts/bounded.sh" 30 "$TMP/p" > "$TMP/got" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL proclimit: probe exited $rc"; cat "$TMP/got"; exit 1; }

# One line per check, compared AS A WHOLE: a row that stops being printed is a
# failure too, and grep would not see it.
cat > "$TMP/want" <<'W'
names include the SUSv3 five ok
every listed name resolves ok
unknown name has no number ok
names are capitals ok
RLIM_INFINITY is decimal ok
unknown constant is empty ok
getrlimit NOFILE ok
errno after success ok
soft within hard ok
field out of range ok
getrlimit unknown name ok
unknown name is EINVAL ok
field after a failed getrlimit ok
setrlimit NOFILE soft 64 ok
NOFILE soft reads 64 ok
NOFILE hard unchanged ok
setrlimit NOFILE restored ok
NOFILE soft reads the original ok
setrlimit CORE soft 0 ok
CORE soft reads 0 ok
setrlimit CORE restored ok
an unlimited resource exists ok
finite soft under unlimited hard ok
finite soft reads back ok
unlimited soft ok
unlimited soft reads -1 ok
soft above hard refused ok
soft above hard is EINVAL ok
CORE untouched by the refusal ok
negative limit refused ok
setrlimit unknown name ok
getpriority process ok
getpriority group ok
getpriority user ok
getpriority bad selector ok
bad selector is EINVAL ok
no such process is ESRCH ok
errno clears on success ok
setpriority up ok
getpriority reads it ok
setpriority bad selector ok
flock exclusive ok
second exclusive refused ok
second shared refused ok
unlock ok
second exclusive after unlock ok
first refused now ok
unlock second ok
shared twice ok
exclusive over shared refused ok
unknown bit refused ok
unknown bit is EINVAL ok
flock a closed fd ok
closed fd is EBADF ok
flock a negative fd ok
W

n=$(wc -l < "$TMP/want" | tr -d ' ')
if diff -u "$TMP/want" "$TMP/got" > "$TMP/d" 2>&1; then
  echo "proclimit: $n/$n ok"
else
  echo "FAIL proclimit: the transcript differs"
  cat "$TMP/d"
  exit 1
fi
