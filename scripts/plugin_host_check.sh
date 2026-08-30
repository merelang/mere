#!/bin/sh
# scripts/plugin_host_check.sh — a host that runs somebody else's Mere code has to
# survive all of it, and this asks whether it does.
#
# The interpreter is the capability boundary and gets that right for free: a
# plugin naming `write_file` or `tcp_connect` does not reach them. That half is
# checked by the ARTIFACT -- a plugin that tries to write
# /tmp/mere_plugin_pwned.txt, and the absence of that file afterwards. Asking the
# diagnostic instead would pass for a host that never ran the plugin at all.
#
# But the interpreter answers only when control REACHES the call, so
# hides_its_request.mere -- which asks for the filesystem from a branch it does
# not take -- used to be accepted and report success. The runner therefore reads
# the program's free names before running it, and the check that this is a
# reading and not a running is that plugin's `print`: it says "I only print,
# honest" before the branch, and that line must NOT appear anywhere in the
# output. A host that reached the same verdict by evaluating would print it.
#
# The other half is that the denial and the host's death are the same event. Mere
# has no way to recover from `fail`, and contrib/eval reaches for it in 20 places
# and contrib/parser in 59, so `parse_and_eval` ends the process that called it --
# for an unknown name, a type error, and a syntax error alike. The host therefore
# runs each plugin as a child, and what this gate checks is that it comes back with
# a VERDICT for every one of them and is still standing at the end.
#
# The corpus is examples/plugin/plugins: one plugin that behaves, two that do not
# stop, two that fail outright, and four that ask for what they were not granted
# -- two of them by asking where running would never notice. Counting the verdicts
# by KIND matters: a host that reported "refused" for all nine would be wrong in a
# way that a "did it survive" check cannot see, and that is not hypothetical --
# a missing MERE in the child's environment produces exactly that shape.
#
# Usage: scripts/plugin_host_check.sh
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
# The host reads MERE to find the binary it runs each plugin with, so it has to
# be in the CHILD's environment and not just this shell's. Run without the
# export and every plugin comes back "exec: mere: not found" -- seven refusals,
# which is a shape this gate would otherwise have to be careful not to accept.
export MERE
PLUGINS=examples/plugin/plugins
PWNED=/tmp/mere_plugin_pwned.txt
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$MERE" ] || { echo "plugin_host_check: $MERE not found — run dune build first" >&2; exit 1; }

rm -f "$PWNED"

# Each runaway plugin is capped at 2 CPU seconds by the HOST, which is the thing
# under test -- so the gate cannot rely on it. A wall-clock bound goes around the
# whole run, because a gate that hangs is worse than one that fails, and the
# corpus here is two programs whose entire purpose is not to stop.
BOUND=120
sh scripts/bounded.sh "$BOUND" "$MERE" examples/plugin/host.mere "$PLUGINS"/*.mere \
  > "$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" = 201 ]; then
  echo "plugin_host_check: FAILED — the run did not finish in ${BOUND}s (a plugin was not stopped)"
  exit 1
fi
if [ "$rc" != 0 ]; then
  echo "plugin_host_check: FAILED — the host did not survive its own corpus (exit $rc)"
  sed 's/^/    /' "$TMP/err" | head -5
  exit 1
fi

n_lines=$(grep -c '  ->  ' "$TMP/out" || true)
n_returned=$(grep -c '  ->  returned' "$TMP/out" || true)
n_denied=$(grep -c '  ->  denied' "$TMP/out" || true)
n_refused=$(grep -c '  ->  refused' "$TMP/out" || true)
n_stopped=$(grep -c '  ->  stopped' "$TMP/out" || true)
n_corpus=$(ls "$PLUGINS"/*.mere | wc -l | tr -d ' ')

fail=0

# Every plugin gets a verdict. Fewer lines than plugins means the host stopped
# partway and said nothing about it.
[ "$n_lines" = "$n_corpus" ] || {
  echo "FAIL  $n_lines verdict(s) for $n_corpus plugin(s)"; fail=1; }

[ "$n_returned" = 1 ] || { echo "FAIL  returned: want 1, got $n_returned"; fail=1; }
[ "$n_denied" = 4 ]   || { echo "FAIL  denied: want 4, got $n_denied"; fail=1; }
[ "$n_refused" = 2 ]  || { echo "FAIL  refused: want 2, got $n_refused"; fail=1; }
[ "$n_stopped" = 2 ]  || { echo "FAIL  stopped: want 2, got $n_stopped"; fail=1; }

# Neither verdict on a hidden request was reached by running. Both plugins print
# before the thing that would give them away -- one behind an untaken branch, one
# behind a declaration it never calls -- so either line appearing in the output
# means the host evaluated its way to the answer and would have missed both.
if grep -q 'I only print, honest' "$TMP/out"; then
  echo "FAIL  hides_its_request ran: its verdict came from evaluation, not from its free names"
  fail=1
fi
if grep -q 'declared, never called' "$TMP/out"; then
  echo "FAIL  declares_an_extern ran: an extern declaration was not read as a request"
  fail=1
fi

# The capability question, asked of the filesystem rather than of a message.
if [ -f "$PWNED" ]; then
  echo "FAIL  a plugin reached the filesystem: $PWNED exists"; fail=1
fi

# A denial must name what was asked for. "Something went wrong" is what the host
# had before the runner learned to read the grant, and it is not a verdict a host
# can act on.
grep -q 'not granted: write_file' "$TMP/out" || {
  echo "FAIL  the filesystem denial does not name write_file"; fail=1; }
grep -q 'not granted: tcp_connect' "$TMP/out" || {
  echo "FAIL  the network denial does not name tcp_connect"; fail=1; }

sed 's/^/    /' "$TMP/out"

if [ "$fail" != 0 ]; then
  echo "plugin_host_check: FAILED"
  exit 1
fi

echo "plugin_host_check: ok  ($n_corpus plugins: $n_returned returned, $n_denied denied, $n_refused refused, $n_stopped stopped; host survived)"
