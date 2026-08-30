#!/bin/sh
# scripts/run_status_check.sh — assert that `run` reports HOW a child died, and
# that both backends report it the same way.
#
# `run : str -> int` is the only channel a Mere program has for the fate of a
# child process, and a plugin host is the program that needs it: it runs somebody
# else's code under a CPU limit and has to tell "returned 101" from "killed at the
# limit". Under the interpreter it could not. `run` spawned `sh -c cmd` and read
# waitpid's answer, and OCaml's waitpid carries OCAML's signal encoding, where
# Sys.sigkill is -7 and Sys.sigxcpu is -27. So `128 + n` produced 121 and 101 --
# not merely different from the shell's 137 and 152, but BELOW 128, where no
# caller testing for a signal will look. The C backend, which asks the operating
# system, was right the whole time.
#
# The fix is not a signal table: the command now runs inside a subshell, so the
# shell we wait on always survives to exit with 128+signal in the system's own
# numbering. That also removes the difference between a command that ends in
# `exec` and one that does not, which is what made the bug intermittent -- adding
# `exec` to a host's command line, a change that should be invisible, turned
# "killed by signal 24" into an ordinary-looking status.
#
# Both halves are checked, because either alone can pass while the property is
# gone: the two backends must AGREE, and they must agree on the RIGHT number
# (a table of expected values, not just equality -- two backends that are both
# wrong agree perfectly).
#
# Usage: scripts/run_status_check.sh
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$MERE" ] || { echo "run_status_check: $MERE not found — run dune build first" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "run_status_check: no C compiler — SKIP"; exit 0; }

cat > "$TMP/kill_self.sh" <<'SH'
kill -9 $$
SH
cat > "$TMP/spin.sh" <<'SH'
while :; do :; done
SH

# case|command|expected status
#   137 = 128 + SIGKILL(9), 152 = 128 + SIGXCPU(24) on Linux and macOS alike.
#   The `exec` rows are the ones that regressed; the plain exit rows are here so
#   that a wrapper which broke ordinary statuses could not pass either.
CASES=$(cat <<CASES
killed_plain|sh $TMP/kill_self.sh|137
killed_exec|exec sh $TMP/kill_self.sh|137
cpu_limit_plain|ulimit -t 1; sh $TMP/spin.sh|152
cpu_limit_exec|ulimit -t 1; exec sh $TMP/spin.sh|152
exit_zero|exit 0|0
exit_nonzero|exit 3|3
CASES
)

EXPECTED=6
ran=0
fail=0

for row in $(printf '%s\n' "$CASES" | tr ' ' '\001'); do
  row=$(printf '%s' "$row" | tr '\001' ' ')
  name=${row%%|*}; rest=${row#*|}
  cmd=${rest%|*}; want=${rest##*|}

  printf 'let rc = run "%s" in print (str_of_int rc)\n' "$cmd" > "$TMP/p.mere"

  got_i=$("$MERE" "$TMP/p.mere" 2>/dev/null | head -1)

  if ! "$MERE" -c "$TMP/p.mere" > "$TMP/p.c" 2>"$TMP/p.err"; then
    echo "FAIL $name  (C backend refused the case)"; sed 's/^/    /' "$TMP/p.err" | head -2
    fail=$((fail + 1)); ran=$((ran + 1)); continue
  fi
  if ! "$CC" -O0 -w "$TMP/p.c" -o "$TMP/p.bin" -lm 2>"$TMP/p.cc"; then
    echo "FAIL $name  (emitted C did not compile)"; sed 's/^/    /' "$TMP/p.cc" | head -2
    fail=$((fail + 1)); ran=$((ran + 1)); continue
  fi
  got_c=$("$TMP/p.bin" 2>/dev/null | head -1)

  ran=$((ran + 1))
  if [ "$got_i" = "$want" ] && [ "$got_c" = "$want" ]; then
    echo "PASS $name  interp=$got_i c=$got_c"
  else
    echo "FAIL $name  want=$want interp=$got_i c=$got_c"
    fail=$((fail + 1))
  fi
done

# A gate that stops early prints only passes and then exits clean. Count.
if [ "$ran" != "$EXPECTED" ]; then
  echo "run_status_check: FAILED — $ran case(s) ran, expected $EXPECTED"
  exit 1
fi

if [ "$fail" != 0 ]; then
  echo "run_status_check: FAILED — $fail of $ran case(s)"
  exit 1
fi

echo "run_status_check: ok  ($ran cases, interp and C agree with the system's numbering)"
