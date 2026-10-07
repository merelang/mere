#!/bin/sh
# stdin_nonblock_check.sh -- a stdin the parent made non-blocking, written to
# late (v0.1.633).
#
# ruby's IO.pipe makes both ends O_NONBLOCK, and a child that reads its script
# from such a pipe asks before the parent has written anything: read(2) says
# EAGAIN. That is not the end of the input, but the C runtime's read_stdin and
# read_line took it for one -- the child ended at once with nothing, and the
# parent's write met a closed pipe. Now they wait for the descriptor to become
# readable and read again; the Wasm host does the same.
#
# The parent here is python3: it hands the child the read end, non-blocking,
# and writes after a pause. Then the same C program with the wait taken out
# must come back empty -- otherwise the scene no longer shows the difference.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "stdin_nonblock: $MERE not found -- run 'dune build'" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "stdin_nonblock: cannot answer (no python3 to be the parent)"; exit 2; }
CC="${CC:-cc}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0

# The child says it is running before it reads, and the parent writes only
# after that and a pause -- a fixed pause alone raced the child's start (a
# freshly built binary can take longer than that to start on macOS, and then
# the input was there before the first read, wait or no wait).
printf 'let _ = print "ready";\nlet b = read_stdin ();\nprint (str_of_int (str_len b))\n' > "$TMP/p.mere"

# feed CMD...: run CMD with a non-blocking pipe on stdin, written once it is up
feed() {
  python3 - "$@" <<'EOF'
import os, subprocess, sys, time
r, w = os.pipe()
os.set_blocking(r, False)
p = subprocess.Popen(sys.argv[1:], stdin=r, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
os.close(r)
first = p.stdout.readline()
time.sleep(0.3)
try:
    os.write(w, b"first\nsecond line\n")
except BrokenPipeError:
    pass
os.close(w)
out = p.stdout.read().decode("utf-8", "replace").strip()
p.wait()
print(out.strip('"'))
EOF
}

want="18"
"$MERE" -c "$TMP/p.mere" > "$TMP/p.c" 2>/dev/null && $CC -O1 -w "$TMP/p.c" -o "$TMP/p" 2>/dev/null \
  || { echo "FAIL stdin_nonblock: the C program did not build"; exit 1; }
got=$(feed "$TMP/p")
if [ "$got" = "$want" ]; then echo "  ok    C: read_stdin waited for the late write"
else echo "  FAIL  C: got [$got], wanted [$want]"; rc=1; fi

# the poison: the same program with the wait taken out reads nothing
sed 's/ferror(stdin) \&\& __lang_stdin_again(errno)/0/g' "$TMP/p.c" > "$TMP/q.c"
if cmp -s "$TMP/p.c" "$TMP/q.c"; then echo "  FAIL  poison: the runtime no longer has the shape it removes"; rc=1
else
  $CC -O1 -w "$TMP/q.c" -o "$TMP/q" 2>/dev/null
  got=$(feed "$TMP/q")
  if [ "$got" = "$want" ]; then echo "  FAIL  poison: without the wait it still read the input -- the scene does not show the difference"; rc=1
  else echo "  ok    poison: without the wait the child read [$got]"; fi
fi

if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  if "$MERE" -w "$TMP/p.mere" > "$TMP/p.wat" 2>/dev/null \
     && wat2wasm --enable-tail-call --enable-threads "$TMP/p.wat" -o "$TMP/p.wasm" 2>/dev/null; then
    got=$(feed node "$ROOT/scripts/run_wasm.js" "$TMP/p.wasm")
    if [ "$got" = "$want" ]; then echo "  ok    Wasm: the host waited too"
    else echo "  FAIL  Wasm: got [$got], wanted [$want]"; rc=1; fi
  else echo "  FAIL  Wasm: the program did not build"; rc=1; fi
else
  echo "  SKIP  Wasm (no wat2wasm/node)"
fi

if [ "$rc" = 0 ]; then echo "stdin_nonblock: ok"; else echo "stdin_nonblock: FAILED"; fi
exit "$rc"
