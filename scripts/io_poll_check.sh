#!/bin/sh
# scripts/io_poll_check.sh — readiness answers the questions it claims to.
#
# Compiles test/io/io_poll_probe.mere with the C backend and diffs its
# transcript. The probe is one process talking to itself over localhost, so
# every line is deterministic; the transcript checks BOTH directions -- that
# ready events arrive when they should AND that no event is invented when
# nothing happened (an empty wait, a deleted fd). It also pins the coded
# would-block returns (-1) on nonblocking read, accept, and write -- write's
# code is new in v0.1.313 and only an impolite writer (one that fills the
# socket buffer against a reader that never reads) can observe it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "io_poll_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "io_poll_check: no C compiler" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$MERE" -c "$ROOT/test/io/io_poll_probe.mere" > "$TMP/p.c" 2>"$TMP/p.err" \
  || { echo "FAIL io_poll: mere -c refused the probe"; cat "$TMP/p.err"; exit 1; }
"$CC" -O1 -w "$TMP/p.c" -o "$TMP/p" 2>"$TMP/cc.err" \
  || { echo "FAIL io_poll: C compile failed"; cat "$TMP/cc.err"; exit 1; }

# the probe has 2s internal timeouts; bound the whole run anyway
sh "$ROOT/scripts/bounded.sh" 30 "$TMP/p" > "$TMP/got" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL io_poll: probe exited $rc"; cat "$TMP/got"; exit 1; }

cat > "$TMP/want" <<'W'
wait0=0
listener=rd
preread=-1
conn=rd data=hi
writable=wr
after_del=0
eof_rd=1 eof=0
accept_wb=-1
write_wb=-1
()
W
diff -u "$TMP/want" "$TMP/got" || { echo "FAIL io_poll: transcript differs"; exit 1; }
echo "io_poll_check: ok"
