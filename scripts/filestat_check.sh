#!/bin/sh
# scripts/filestat_check.sh — the file_* metadata externs, checked against
# values the probe sets itself.
#
# WHY THESE ARE A RUNTIME AND NOT AN `extern` A PROGRAM WRITES. Mere's extern
# ABI emits `extern int f(const char*, int)`, and every metadata syscall is
# outside what that can name: stat(2) fills a struct, readlink(2) fills the
# CALLER's buffer, and chmod/chown/truncate/umask/mkfifo/utime take a typedef
# (mode_t, uid_t, off_t, time_t) that COLLIDES with the plain `int` in the
# emitted prototype. Declared by hand they do not fail to link -- they fail to
# compile. The runtime in codegen_c.ml is written with the real headers, so
# the struct layout and the typedef widths stay on that side.
#
# ...WITH ONE EXCLUSION: atime. An earlier version asserted it after utime,
# passed, and failed on the very next run with the wall clock -- on a real
# machine something else reads the file (Spotlight's indexer here), and an
# access time is not the program's to own. mtime is.
#
# EVERY EXPECTATION IS A VALUE THE PROBE SET. It chmods and reads the mode
# back, truncates and reads the size, utimes and reads the mtime, symlinks and
# reads the link. Nothing here is a snapshot of one machine, so the gate is
# the same on any POSIX host.
#
# THIS GATE HAS ALREADY EARNED ITS KEEP. The first runtime cached the stat
# keyed by path and took the snapshot implicitly inside the field read. The
# probe failed three rows on the first run -- mode after chmod, size after
# truncate, mtime after utime -- all one root: a cache that a write does not
# invalidate. The API is an explicit snapshot now because of that run.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "filestat_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "filestat_check: no C compiler" >&2; exit 0; }

TMP="$(mktemp -d)"
# the probe writes these fixed paths; a leftover link or fifo from a killed
# run would make mkfifo/symlink fail, so they go too.
trap 'rm -rf "$TMP" /tmp/mere_filestat_probe /tmp/mere_filestat_probe_link /tmp/mere_filestat_probe_fifo' EXIT
rm -f /tmp/mere_filestat_probe_link /tmp/mere_filestat_probe_fifo

"$MERE" -c "$ROOT/test/filestat/filestat_probe.mere" > "$TMP/p.c" 2>"$TMP/p.err" \
  || { echo "FAIL filestat: mere -c refused the probe"; cat "$TMP/p.err"; exit 1; }
"$CC" -O1 -w "$TMP/p.c" -o "$TMP/p" 2>"$TMP/cc.err" \
  || { echo "FAIL filestat: C compile failed"; cat "$TMP/cc.err"; exit 1; }

sh "$ROOT/scripts/bounded.sh" 30 "$TMP/p" > "$TMP/got" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL filestat: probe exited $rc"; cat "$TMP/got"; exit 1; }

# The probe prints one line per check. A FAIL line carries got= and want=, so
# the transcript is compared as a whole rather than grepped: a row that stops
# being printed at all is a failure too, and grep would not see it.
cat > "$TMP/want" <<'W'
chmod 0644 ok
chmod 0600 ok
size ok
size after truncate ok
missing file ok
field after a failed stat ok
present file ok
field out of range ok
umask round trip ok
utime/mtime ok
readlink ok
readlink length ok
readlink on a non-link ok
lstat sees the link, stat sees through it ok
mkfifo type bits ok
mkfifo permission bits ok
W
diff -u "$TMP/want" "$TMP/got" || { echo "FAIL filestat: transcript differs"; exit 1; }
echo "filestat_check: ok"
