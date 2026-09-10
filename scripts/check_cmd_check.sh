#!/bin/sh
# scripts/check_cmd_check.sh — `mere check` accepts exactly what the compile
# path accepts, and its backend forms see what codegen refuses.
#
# WHAT IT IS FOR. Before this subcommand the only way to ask "is this program
# accepted" was to compile it and throw the output away, and the only cheap
# thing that looked like an answer was `mere -t` -- which runs the declaration
# loop and NOT the borrow or spawn-capture or exhaustiveness checks, and says so
# in its own help. `examples/borrow_conflict.mere` is the standing proof: `-t`
# exits 0 on it and every compiled backend refuses it.
#
# So the hazard `mere check` is exposed to is becoming a second `-t`: a fast
# answer to a different question. That is not something three hand-picked cases
# can hold, because the failure would be a program nobody thought to pick. The
# main check here is therefore a DIFFERENTIAL over the whole examples tree.
#
# WHAT IT CHECKS.
#
#   A. `mere check -c` and `mere -c` agree on EVERY example, exactly. They run
#      the same work and differ only in whether the bytes are printed, so a
#      disagreement is the subcommand having grown its own opinion.
#
#   B. `mere check` accepts everything `mere -c` accepts. A check that refuses
#      a program which builds is worse than no check: it sends people to look
#      for a bug that is in the checker.
#
#   C. Where `mere check` accepts and `mere -c` refuses, the refusal came from
#      codegen -- and `mere check -c` must then refuse it too. This is the one
#      gap the bare form has, and this is what holds it to being that gap and
#      not a wider one.
#
#   D. The reason it exists, as a case: `-t` accepts `borrow_conflict.mere` and
#      `mere check` refuses it. If that inverts, the subcommand has become `-t`.
#
#   E. Silence on success. A check tool that prints on the good path cannot be
#      put in a loop, and the exit status is the whole interface.
#
#   F. A per-backend refusal that the bare form CANNOT see is seen by the flag
#      (`test/parity/bytebuf_edges.mere`: bare check accepts, `-ll` and `-w`
#      refuse). Without this, C could be satisfied vacuously by a corpus in
#      which no backend ever refuses anything.
#
#   G. Usage errors: no path, and more arguments than it takes.
#
# Usage:
#   sh scripts/check_cmd_check.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}

if [ ! -x "$MERE" ]; then
  echo "check_cmd_check: $MERE not found — run dune build first" >&2
  exit 1
fi

cd "$ROOT" || exit 1

fail=0
checked=0

# --- A / B / C: the differential over examples/ ---------------------------
#
# Three runs per file. `check` is the cheap one (5s for the tree); the two
# compile runs are ~11s each, which is what asking the question honestly costs.

swept=0
codegen_only=0        # accepted by check, refused by a backend (the C rows)
disagree_a=0

for f in examples/*.mere; do
  [ -f "$f" ] || continue
  swept=$((swept + 1))

  "$MERE" check "$f" >/dev/null 2>&1;    chk=$?
  "$MERE" -c "$f" >/dev/null 2>&1;       cc=$?
  "$MERE" check -c "$f" >/dev/null 2>&1; chkc=$?

  # A. the flag form is the compile path
  if [ "$chkc" != "$cc" ]; then
    echo "FAIL A: $f — 'check -c' exited $chkc, '-c' exited $cc"
    disagree_a=$((disagree_a + 1))
    fail=1
  fi

  # B. check must not refuse what builds
  if [ "$cc" = 0 ] && [ "$chk" != 0 ]; then
    echo "FAIL B: $f — '-c' builds it, but 'check' refused it (exit $chk)"
    "$MERE" check "$f" 2>&1 | sed -n '1,6p'
    fail=1
  fi

  # C. a refusal check cannot see must be a codegen refusal, and the flag form
  #    must see it
  if [ "$chk" = 0 ] && [ "$cc" != 0 ]; then
    codegen_only=$((codegen_only + 1))
    if [ "$chkc" = 0 ]; then
      echo "FAIL C: $f — 'check' and 'check -c' both accept it, but '-c' refuses it"
      fail=1
    fi
  fi
done

checked=$((checked + swept * 3))

if [ "$swept" -lt 100 ]; then
  echo "FAIL: only $swept examples swept, expected at least 100 — the corpus moved"
  fail=1
fi

# --- D: the reason it exists ----------------------------------------------

borrow=examples/borrow_conflict.mere
if [ ! -f "$borrow" ]; then
  echo "FAIL D: $borrow is gone — the case this subcommand was written for"
  fail=1
else
  "$MERE" -t "$borrow" >/dev/null 2>&1;    t_rc=$?
  "$MERE" check "$borrow" >/dev/null 2>&1; c_rc=$?
  "$MERE" -c "$borrow" >/dev/null 2>&1;    b_rc=$?
  checked=$((checked + 3))
  if [ "$t_rc" != 0 ]; then
    echo "FAIL D: -t now REFUSES $borrow (exit $t_rc). It used to accept it, which"
    echo "        is the gap 'check' was written to close — if -t has grown the"
    echo "        borrow check, say so here and in the help text."
    fail=1
  fi
  if [ "$c_rc" = 0 ]; then
    echo "FAIL D: 'check' accepted $borrow — it has become a second -t"
    fail=1
  fi
  if [ "$b_rc" = 0 ]; then
    echo "FAIL D: '-c' accepted $borrow — the borrow conflict is no longer refused"
    fail=1
  fi
fi

# --- E: silence on success ------------------------------------------------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'print "hi"\n' > "$TMP/ok.mere"
# BYTES, not `$(...)`. Command substitution strips trailing newlines, so the
# first version of this could not tell "printed nothing" from "printed one
# blank line" -- and `check` returns the empty string, so dropping its
# `~quiet:true` printed exactly that newline and this check stayed green. A
# silence check has to count bytes.
"$MERE" check "$TMP/ok.mere" > "$TMP/ok.out" 2>&1
rc=$?
bytes=$(wc -c < "$TMP/ok.out" | tr -d ' \t')
checked=$((checked + 2))
if [ "$rc" != 0 ]; then
  echo "FAIL E: 'check' refused a hello-world (exit $rc):"
  sed -n '1,4p' "$TMP/ok.out"
  fail=1
fi
if [ "$bytes" != 0 ]; then
  echo "FAIL E: 'check' wrote $bytes byte(s) on the good path, so it cannot go"
  echo "        in a loop. Output, as bytes:"
  od -c "$TMP/ok.out" | sed -n '1,3p'
  fail=1
fi

# --- F: a refusal only the flag form can see ------------------------------
#
# Not "some file somewhere disagrees" -- a named one, so C cannot pass by the
# corpus having no such row at all.

bb=test/parity/bytebuf_edges.mere
if [ ! -f "$bb" ]; then
  echo "FAIL F: $bb is gone — the standing example of a per-backend refusal"
  fail=1
else
  "$MERE" check "$bb" >/dev/null 2>&1;     f_bare=$?
  "$MERE" check -ll "$bb" >/dev/null 2>&1; f_ll=$?
  "$MERE" check -w "$bb" >/dev/null 2>&1;  f_w=$?
  checked=$((checked + 3))
  if [ "$f_bare" != 0 ]; then
    echo "FAIL F: bare 'check' refused $bb (exit $f_bare) — it type-checks; the"
    echo "        refusal belongs to the LLVM and Wasm emitters."
    fail=1
  fi
  if [ "$f_ll" = 0 ] && [ "$f_w" = 0 ]; then
    echo "FAIL F: neither 'check -ll' nor 'check -w' refused $bb, so the flag"
    echo "        forms are not reaching codegen. If both backends grew support,"
    echo "        this file is no longer the example and the gate needs another."
    fail=1
  fi
fi

# --- G: usage errors ------------------------------------------------------

# `rc` is read straight after the command: putting the `checked` increment
# between them reads the ASSIGNMENT's status, which is always 0, and this gate
# reported both of these as failures on its first run.
"$MERE" check >/dev/null 2>&1; rc=$?
checked=$((checked + 1))
[ "$rc" = 0 ] && { echo "FAIL G: 'check' with no path exited 0"; fail=1; }

"$MERE" check "$TMP/ok.mere" "$TMP/ok.mere" >/dev/null 2>&1; rc=$?
checked=$((checked + 1))
[ "$rc" = 0 ] && { echo "FAIL G: 'check' with two paths exited 0"; fail=1; }

# --- verdict --------------------------------------------------------------

if [ "$checked" -lt 300 ]; then
  echo "FAIL check_cmd_check: only $checked checks ran, expected at least 300"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "check_cmd_check: OK ($swept examples x 3, $codegen_only codegen-only refusal(s), $checked checks)"
else
  echo "check_cmd_check: FAILED ($checked checks, $disagree_a A-disagreements)"
fi
exit "$fail"
