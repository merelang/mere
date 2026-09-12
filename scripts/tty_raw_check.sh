#!/bin/sh
# scripts/tty_raw_check.sh — does a key a program asked for actually arrive?
#
# THIS GATE EXISTS BECAUSE A PIPE IS NOT A TERMINAL, and every tty test in this
# project was a pipe. Through a pipe there is no line discipline: every byte
# written arrives, so `tty_raw` looks like it works no matter what it sets.
# Under a real terminal the discipline is between the keyboard and the program
# and takes some keys for itself.
#
# What that cost, measured rather than imagined: the `medit` dogfood documents
# Ctrl-S as save and Ctrl-Q as quit. With IXON left on those are XOFF and XON,
# so the discipline ate both -- driven under a pty it drew ZERO bytes after each
# and never wrote its file. An editor that could not be saved or quit from,
# published, for two months, with green piped tests the whole time.
#
# So this drives a Mere program through a REAL PTY and asks whether the bytes it
# was sent reached it. Three keys, one per property:
#
#   Ctrl-S (19)  IXON cleared by tty_raw           -- a fix; nothing wants XOFF
#   Ctrl-Z (26)  ISIG cleared by tty_no_signal_keys -- opt-in; costs Ctrl-C
#   Ctrl-C (3)   ISIG *kept* under tty_raw alone    -- the other side of that
#
# The third leg is the one that keeps the trade honest. If a later change folds
# the signal keys into tty_raw, every existing TUI silently loses its escape
# hatch -- so that direction is pinned too, and this goes red instead.
#
# Usage:  sh scripts/tty_raw_check.sh

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}
[ -x "$MERE" ] || { echo "tty_raw_check: $MERE not found — run dune build first" >&2; exit 1; }
CC=$(command -v clang || command -v cc || true)
[ -n "$CC" ] || { echo "tty_raw_check: no C compiler — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "tty_raw_check: no python3 (needs one to open a pty) — skipping"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
checked=0

# The subject: read bytes and print their codes, so what reached the program is
# visible from outside. `argv` decides how much of the terminal it takes over.
cat > "$TMP/keys.mere" <<'MERE'
let argv = args ();
let rec has = fn (xs: str list) -> fn (w: str) ->
  match xs with
  | Nil -> false
  | Cons (x, rest) -> if str_eq x w then true else has rest w;

let _ = tty_raw ();
let _ = if has argv "--nosig" then tty_no_signal_keys () else ();
// The driver waits for this before sending anything. Sleeping instead loses a
// race it cannot see: a byte sent before tty_raw has run meets a terminal still
// in canonical mode with IXON on, and Ctrl-S is swallowed as XOFF -- which
// looks exactly like the bug this gate is here to catch.
let _ = print "ready";

let rec loop = fn (n: int) ->
  if n <= 0 then ()
  else
    let k = read_key () in
    if str_eq k "" then ()
    else
      let _ = print ("got " ++ show (ord k)) in
      loop (n - 1);
let _ = loop 3;
let _ = tty_restore ();
print "done"
MERE

"$MERE" -c "$TMP/keys.mere" > "$TMP/keys.c" 2>"$TMP/emit.err" || {
  echo "FAIL tty_raw_check: the subject did not compile"; cat "$TMP/emit.err" >&2; exit 1; }
$CC -O1 -w "$TMP/keys.c" -o "$TMP/keys" 2>/dev/null || {
  echo "FAIL tty_raw_check: the subject did not link"; exit 1; }

# Drive it under a pty and report which of the sent bytes came back named.
cat > "$TMP/drive.py" <<'PY'
import os, pty, select, struct, fcntl, termios, time, sys, signal

binary, keys, args = sys.argv[1], sys.argv[2], sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(binary, [binary] + args)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

def drain(seconds=1.0, quiet=0.15):
    out, deadline, last = b"", time.time() + seconds, time.time()
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.02)
        if not r:
            if time.time() - last >= quiet:
                break
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        last = time.time()
    return out

# Wait for the subject to say it has taken over the terminal. A fixed sleep
# here is a race the gate cannot see -- and it loses in the direction that
# fabricates a failure, because a byte sent too early is eaten exactly the way
# the bug eats it.
ready, deadline = b"", time.time() + 5.0
while b"ready" not in ready and time.time() < deadline:
    ready += drain(0.3)
if b"ready" not in ready:
    print("GONE")
    sys.stdout.write("SUBJECT NEVER SIGNALLED READY\n")
    sys.exit(0)

for k in keys.split(","):
    try:
        os.write(fd, bytes([int(k)]))
    except OSError:
        # The child is gone. On the Ctrl-C leg that is the EXPECTED outcome --
        # the signal killed it and the later keys have nowhere to go -- so this
        # is not an error to report, it is the evidence the leg is looking for.
        break
    time.sleep(0.05)
seen = drain(2.0)
# Whether the CHILD is still alive matters for the Ctrl-C leg: there, the key
# not arriving is the point, and the signal killing it is the evidence.
time.sleep(0.2)
try:
    alive = os.waitpid(pid, os.WNOHANG) == (0, 0)
except ChildProcessError:
    alive = False
try:
    os.kill(pid, signal.SIGKILL)
except Exception:
    pass
os.close(fd)
print("ALIVE" if alive else "GONE")
sys.stdout.write(seen.decode("utf-8", "replace"))
PY

run() { python3 "$TMP/drive.py" "$TMP/keys" "$@"; }

# ---- Ctrl-S and Ctrl-Q arrive under plain tty_raw ------------------------
# The two keys medit uses, and the two the line discipline used to eat.
out=$(run "19,17,65")
for want in "got 19" "got 17"; do
  if ! printf '%s' "$out" | grep -q "$want"; then
    echo "FAIL tty_raw_check: '$want' never reached the program."
    echo "  tty_raw has to clear IXON: with it on, Ctrl-S is XOFF and Ctrl-Q is XON,"
    echo "  the line discipline consumes both, and a program that documents them as"
    echo "  keys cannot be saved or quit from. See __lang_tty_raw in codegen_c.ml."
    fail=1
  fi
  checked=$((checked + 1))
done

# ---- Ctrl-Z arrives once the program has asked for it --------------------
out=$(run "26,65,66" --nosig)
if ! printf '%s' "$out" | grep -q "got 26"; then
  echo "FAIL tty_raw_check: Ctrl-Z did not reach a program that called tty_no_signal_keys."
  echo "  With ISIG set, 0x1a is SUSP and never becomes a byte, so an editor's undo"
  echo "  silently does nothing -- and a piped test cannot see it, because a pipe has"
  echo "  no line discipline and 0x1a arrives there either way."
  fail=1
fi
checked=$((checked + 1))

# ---- and Ctrl-C still interrupts a program that did NOT ask --------------
# The other side of the trade. A game that quits on `q` keeps its escape hatch;
# folding ISIG into tty_raw would take it away from every existing TUI.
out=$(run "3,65,66")
if printf '%s' "$out" | grep -q "^ALIVE"; then
  echo "FAIL tty_raw_check: Ctrl-C did not interrupt a program under plain tty_raw."
  echo "  ISIG belongs to tty_no_signal_keys, which a caller opts into knowing it"
  echo "  gives up the interrupt key. If taking it away by default is now the"
  echo "  intended trade, change this leg deliberately rather than letting it pass."
  fail=1
fi
checked=$((checked + 1))
if printf '%s' "$out" | grep -q "got 3"; then
  echo "FAIL tty_raw_check: Ctrl-C arrived as a BYTE under plain tty_raw — ISIG is off"
  echo "  when nothing asked for it."
  fail=1
fi
checked=$((checked + 1))

if [ "$fail" = "0" ]; then
  echo "PASS tty_raw_check: $checked checks — Ctrl-S/Ctrl-Q reach the program, Ctrl-Z reaches it on request, Ctrl-C still interrupts when it was not asked for"
  exit 0
fi
exit 1
