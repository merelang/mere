#!/bin/sh
# scripts/procsig_check.sh — proc_sig_noop / proc_sig_default / proc_sig_raise
# and proc_out_errno, each in the scene it is for.
#
# WHY THESE ARE A RUNTIME AND NOT AN `extern`. signal(2) and sigaction(2) move
# a disposition through a function pointer and a struct, which no extern can
# spell. And the refusal of a write to stdout was dropped inside the runtime
# (__lang_write_all), before any program could ask for it.
#
# WHAT THEY ARE FOR. A program that writes to pipes wants SIGPIPE not to end
# it, and wants a write nobody reads any more to be an error it can see --
# ruby's Errno::EPIPE. SIG_IGN gives the first and passes it on: an ignored
# signal stays ignored across exec(2), so every child started afterwards
# ignored SIGPIPE too and, with the refusal dropped, wrote into a closed pipe
# for as long as it ran (mere-ruby's child `loop { puts :ok }` under CRuby's
# test_io, 94 seconds). ruby installs a handler that does nothing instead; a
# handler goes back to the default at exec. proc_sig_noop is that, with
# ruby's rule for an inherited disposition (not the default: put back, kept).
#
# THE SCENES. Each row below is one mode of the probe, run in the scene its
# question needs: nothing inherited; SIG_IGN inherited (`trap '' PIPE`, which
# the shell passes on at exec); stdout a pipe whose reader has exited; and a
# run that must END of the signal, read as 141 from the shell.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "procsig_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "procsig_check: no C compiler" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$MERE" -c "$ROOT/test/procsig/procsig_probe.mere" > "$TMP/p.c" 2>"$TMP/p.err" \
  || { echo "FAIL procsig: mere -c refused the probe"; cat "$TMP/p.err"; exit 1; }
"$CC" -O1 -w "$TMP/p.c" -o "$TMP/p" 2>"$TMP/cc.err" \
  || { echo "FAIL procsig: C compile failed"; cat "$TMP/cc.err"; exit 1; }
P="$TMP/p"

: > "$TMP/got"
sh "$ROOT/scripts/bounded.sh" 30 "$P" fresh 2>> "$TMP/got"
echo "fresh exit $?" >> "$TMP/got"
( trap '' PIPE; sh "$ROOT/scripts/bounded.sh" 30 "$P" inherited ) 2>> "$TMP/got"
echo "inherited exit $?" >> "$TMP/got"
# the reader exits at once; the probe waits 300 ms before its first write
sh "$ROOT/scripts/bounded.sh" 30 "$P" closed 2>> "$TMP/got" | true
sh "$ROOT/scripts/bounded.sh" 30 "$P" dies 2>> "$TMP/got"
echo "dies exit $?" >> "$TMP/got"

# One line per check, compared AS A WHOLE: a row that stops being printed is a
# failure too, and grep would not see it.
cat > "$TMP/want" <<'W'
noop installs ok
errno after success ok
noop again installs ok
raise under the handler ok
survived the signal ok
a child has the default ok
no refusal yet ok
unknown signal refused ok
unknown signal is EINVAL ok
default unknown refused ok
fresh exit 0
inherited ignore kept ok
raise while ignored ok
survived the ignored signal ok
a child still ignores it ok
inherited exit 0
noop installs ok
refused write is EPIPE ok
asking clears it ok
print_bytes refusal is EPIPE ok
default restored ok
dies exit 141
W

n=$(wc -l < "$TMP/want" | tr -d ' ')
if diff -u "$TMP/want" "$TMP/got" > "$TMP/d" 2>&1; then
  echo "procsig: $n/$n ok"
else
  echo "FAIL procsig: the transcript differs"
  cat "$TMP/d"
  exit 1
fi
