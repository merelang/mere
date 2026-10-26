#!/bin/sh
# scripts/syslog_check.sh — sys_openlog, sys_syslog, sys_closelog and
# sys_setlogmask (v0.1.677), checked through LOG_PERROR.
#
# The system log is the host's (the unified log on macOS, /dev/log on Linux)
# and cannot be read back the same way on both, so the probe also asks for
# LOG_PERROR and this script reads stderr. The line's shape is the host
# libc's ("mereprobe: hello" on glibc, a date, pid and level on macOS), so
# only what both have is compared: the ident and the message on one line.
#
# What it guards: the message is never the FORMAT ("100% %s %n" arrives as
# written; as a format, %n writes through a pointer), the ident survives the
# temporary string it was made from, a masked priority sends nothing, and a
# second openlog after closelog logs under the new ident.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "syslog_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "syslog_check: could not answer, no C compiler" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$MERE" -c "$ROOT/test/syslog/syslog_probe.mere" > "$TMP/p.c" 2>"$TMP/p.err" \
  || { echo "FAIL syslog: mere -c refused the probe"; cat "$TMP/p.err"; exit 1; }
"$CC" -O1 -w -pthread "$TMP/p.c" -o "$TMP/p" 2>"$TMP/cc.err" \
  || { echo "FAIL syslog: C compile failed"; cat "$TMP/cc.err"; exit 1; }
sh "$ROOT/scripts/bounded.sh" 30 "$TMP/p" > "$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL syslog: probe exited $rc"; cat "$TMP/out" "$TMP/err"; exit 1; }

fail=0
n=0
check() { n=$((n + 1)); if eval "$2"; then :; else echo "FAIL syslog: $1"; fail=1; fi; }
check "every row of the probe" '! grep -q FAIL "$TMP/out" && [ "$(grep -c " ok$" "$TMP/out")" -eq 10 ]'
check "the message under its ident" 'grep -q "mereprobe.*hello 100% %s %n" "$TMP/err"'
check "a masked priority sent nothing" '! grep -q "masked out" "$TMP/err"'
check "the second ident" 'grep -q "mereprobe2.*second" "$TMP/err"'
check "nothing else on stderr" '[ "$(wc -l < "$TMP/err" | tr -d " ")" -eq 2 ]'
if [ "$fail" -eq 0 ]; then
  echo "syslog: $n/$n ok"
else
  cat "$TMP/out" "$TMP/err"
  exit 1
fi
