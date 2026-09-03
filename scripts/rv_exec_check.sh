#!/bin/sh
# scripts/rv_exec_check.sh — run hosted -rv programs and check what they print.
#
# scripts/parity.sh compares four backends by output; RV32I is not one of them,
# because running its output needs a machine. So everything about that backend
# that is a matter of RUNTIME behaviour rather than emitted instructions had no
# gate at all: `scripts/qemu_virt.sh` covers the bare-metal side, and this covers
# the hosted side.
#
# What that gap cost: a `try_or` whose thunk failed restored sp and fp and not the
# callee-saved registers, so the catching function's own named bindings came back
# holding whatever the failed callee had put there. Five lines of Mere show it. The
# suite had a try_or test whose thunk had no bindings of its own, so there was
# nothing to overwrite and all four backends agreed.
#
# Each program is run on the interpreter and on RV32I, and the two outputs must be
# identical -- so the expected values are not written down anywhere here.
#
# Needs a 32-bit machine: MEMU=<memu checkout>. Without it the programs are still
# COMPILED for RV32I, and this says the running half did not happen.
#
# Usage:
#   sh scripts/rv_exec_check.sh
#   MEMU=/path/to/memu sh scripts/rv_exec_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "rv_exec_check: $MERE not found — run 'dune build'" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0; pass=0; fail=0

# The whole parity corpus, not a hand-picked five. That suite exists because four
# backends should agree; RV32I is not one of the four, so nothing compared it
# against anything until now. Sweeping it found a `<` on a nullary variant
# answering from allocation order, a Map comparing non-string keys as strings, and
# a try_or that did not restore the catcher's registers.
#
# The reference is the C backend and not the interpreter: both are compiled
# programs, so neither is doing anything the other cannot.
#
# KNOWN DIFFERENCES, by name and reason. A program not in this list that differs
# fails the gate; a program IN it that stops differing also fails, so the list
# cannot quietly outlive its reasons.
KNOWN_DIFF="float_edges str_edges region_growth graphql_stack_portable map_compact"
# float_edges/str_edges             64-bit values; this backend's int is 32 bits
#   (coll_edges and nul_in_str sat here too, on the strength of a 60-second
#    alarm that was really a measurement of how slow decimal printing is on an
#    emulated CPU -- with a longer alarm both agree, and the freshness check
#    below is what said so. The alarm is 480s for the same reason: a program
#    that was cut off mid-print reads as a difference, and the cut moves with
#    host load, which made the gate FLAKY at 60 and at 240.)
# region_growth                     wants more RAM (and more time) than the sweep gives it
# graphql_stack_portable            polymorphic == is a word comparison here
#   (other backends monomorphize; the stdlib's list_member misses a
#    content-equal string in a different block -- test/rv/poly_eq_word.mere
#    pins the behaviour and names monomorphization as the fix)
# map_compact                       map_bytes measures an arena; a Vec here has none

RVRUN=""
if [ -n "${MEMU:-}" ]; then
  [ -f "$MEMU/riscv-runc/rv32i_run.mere" ] || { echo "FAIL rv_exec: no rv32i_run.mere under MEMU=$MEMU"; exit 1; }
  "$MERE" -c "$MEMU/riscv-runc/rv32i_run.mere" > "$TMP/rvrun.c" 2>"$TMP/err" || {
    echo "FAIL rv_exec: the emulator did not compile"; head -5 "$TMP/err"; exit 1; }
  $CC -O2 -w -o "$TMP/rvrun" "$TMP/rvrun.c" || { echo "FAIL rv_exec: cc refused the emulator"; exit 1; }
  RVRUN="$TMP/rvrun"
fi

echoed=0; known=0; nocref=0; refused=0; refused_names=""
for p in "$ROOT"/test/parity/*.mere; do
  name=$(basename "$p" .mere)
  if "$MERE" -c "$p" > "$TMP/ref.c" 2>/dev/null && $CC -O1 -w -o "$TMP/ref" "$TMP/ref.c" 2>/dev/null; then
  ( ulimit -t 60; "$TMP/ref" ) > "$TMP/i.out.raw" 2>&1
  # -a: nul_in_str's output HAS a NUL, and without it grep's binary-file
  # heuristic swallows lines -- nondeterministically, because the heuristic
  # looks at buffer boundaries. This gate flaked at 60s, at 240s, and then
  # kept flaking with no timeout in sight; the timeout was never the reason.
  grep -a -v '^()$' "$TMP/i.out.raw" > "$TMP/i.out"
  else
    nocref=$((nocref+1)); continue   # not a C-backend program; nothing to compare against
  fi
  if "$MERE" -rv --ram 32 "$p" > "$TMP/prog.bin" 2>"$TMP/rverr"; then :; else
    # Refused for a named reason -- scripts/host_matrix.sh's business, not a
    # failure here. But COUNTED and NAMED, not silently dropped: this gate's
    # "N passed" read as coverage of the corpus, and it was really coverage of
    # the roughly half of it this backend accepts (70 of 144 were skipped
    # here, invisibly, when this was a bare `continue`). A gate that does not
    # state its denominator claims the whole corpus every time it goes green.
    refused=$((refused+1)); refused_names="$refused_names $name"; continue
  fi
  if [ -z "$RVRUN" ]; then pass=$((pass+1)); continue; fi
  ( cd "$TMP" && perl -e 'alarm 480; exec @ARGV' ./rvrun 32 2>/dev/null ) | grep -a -v '^rvrun: ' > "$TMP/r.out"
  # The reference prints the program's own final value and an RV32I binary does
  # not, so an output that matches except for that last line is the ONE accepted
  # shape -- spelled out rather than filtered, so a real difference in the last
  # line is still a difference.
  sed '$d' "$TMP/i.out" > "$TMP/i.trim"
  expected_diff=no
  for k in $KNOWN_DIFF; do [ "$k" = "$name" ] && expected_diff=yes; done
  if diff -q "$TMP/i.out" "$TMP/r.out" >/dev/null; then agree=yes
  elif diff -q "$TMP/i.trim" "$TMP/r.out" >/dev/null; then agree=yes; echoed=$((echoed+1))
  else agree=no; fi
  if [ "$agree" = yes ] && [ "$expected_diff" = yes ]; then
    printf '  FAIL  %s is in KNOWN_DIFF but now agrees — remove it from the list\n' "$name"
    fail=$((fail+1)); rc=1
  elif [ "$agree" = yes ]; then pass=$((pass+1))
  elif [ "$expected_diff" = yes ]; then known=$((known+1))
  else
    printf '  FAIL  %s (RV32I disagrees with the C backend)\n' "$name"
    # -a: these outputs can contain NUL, and without it diff says only "binary
    # files differ", which names nothing.
    diff -a "$TMP/i.out" "$TMP/r.out" | head -8 | sed 's/^/    /'
    fail=$((fail+1)); rc=1
  fi
done

# test/rv/ holds programs that cannot sit in the parity corpus because some
# OTHER backend refuses them. region_map_escape: Wasm refuses a map mutation
# inside a region at compile time (it rolls the whole block back); this backend
# keeps the heap instead, and the C reference agrees on what the program prints.
name=region_map_escape
if "$MERE" -c "$ROOT/test/rv/region_map_escape.mere" > "$TMP/ref.c" 2>/dev/null \
   && $CC -O1 -w -o "$TMP/ref" "$TMP/ref.c" 2>/dev/null \
   && "$MERE" -rv "$ROOT/test/rv/region_map_escape.mere" > "$TMP/prog.bin" 2>"$TMP/rverr"; then
  ( ulimit -t 60; "$TMP/ref" ) 2>&1 | grep -a -v '^()$' > "$TMP/i.out"
  if [ -z "$RVRUN" ]; then pass=$((pass+1))
  else
    ( cd "$TMP" && perl -e 'alarm 60; exec @ARGV' ./rvrun 8 2>/dev/null ) | grep -a -v '^rvrun: ' > "$TMP/r.out"
    if diff -q "$TMP/i.out" "$TMP/r.out" >/dev/null; then
      printf '  ok    %s (a region does not reclaim a live map cell)\n' "$name"; pass=$((pass+1))
    else
      printf '  FAIL  %s\n' "$name"; diff "$TMP/i.out" "$TMP/r.out" | head -6 | sed 's/^/    /'
      fail=$((fail+1)); rc=1
    fi
  fi
else
  printf '  FAIL  %s did not build\n' "$name"; head -2 "$TMP/rverr"; fail=$((fail+1)); rc=1
fi

# poly_eq_word: the pinned known limitation (see the file's header). Its
# expected output IS the wrong answer, so the pin breaks the day the backend
# learns to specialize -- symmetrical with the KNOWN_DIFF freshness check.
name=poly_eq_word
if "$MERE" -rv "$ROOT/test/rv/poly_eq_word.mere" > "$TMP/prog.bin" 2>"$TMP/rverr"; then
  if [ -z "$RVRUN" ]; then pass=$((pass+1))
  else
    ( cd "$TMP" && perl -e 'alarm 60; exec @ARGV' ./rvrun 8 2>/dev/null ) | grep -a -v '^rvrun: ' > "$TMP/r.out"
    if grep -q UNEXPECTED "$TMP/r.out"; then
      printf '  FAIL  %s (the pinned behaviour changed -- read the pin)\n' "$name"
      grep UNEXPECTED "$TMP/r.out" | sed 's/^/    /'
      fail=$((fail+1)); rc=1
    else
      printf '  ok    %s (known limitation, pinned)\n' "$name"; pass=$((pass+1))
    fi
  fi
else
  printf '  FAIL  %s did not build\n' "$name"; fail=$((fail+1)); rc=1
fi

# host_services: time and random_int have no other backend to diff against --
# nondeterministic by contract -- so the program checks properties and this
# just requires every line to say ok.
name=host_services
if "$MERE" -rv "$ROOT/test/rv/host_services.mere" > "$TMP/prog.bin" 2>"$TMP/rverr"; then
  if [ -z "$RVRUN" ]; then pass=$((pass+1))
  else
    ( cd "$TMP" && perl -e 'alarm 60; exec @ARGV' ./rvrun 8 2>/dev/null ) | grep -a -v '^rvrun: ' > "$TMP/r.out"
    if grep -q FAIL "$TMP/r.out" || ! grep -q "^ok" "$TMP/r.out"; then
      printf '  FAIL  %s\n' "$name"; head -6 "$TMP/r.out" | sed 's/^/    /'
      fail=$((fail+1)); rc=1
    else
      printf '  ok    %s (%s properties hold)\n' "$name" "$(grep -c '^ok' "$TMP/r.out")"
      pass=$((pass+1))
    fi
  fi
else
  printf '  FAIL  %s did not build\n' "$name"; head -2 "$TMP/rverr"; fail=$((fail+1)); rc=1
fi

# One case cannot be a differential: an `extern fn` that nothing implements has no
# behaviour on any other backend to compare against -- the interpreter refuses the
# program outright ("no interp mock implementation"). So its expectation is written
# out, and it is the only one here that is. What it pins is that the refusal is a
# `fail` and not an exit, which is what lets a program cope at all.
EXPECTED='pid=-1 other=99
still running'
name=extern_catchable
if "$MERE" -rv "$ROOT/test/rv/extern_catchable.mere" > "$TMP/prog.bin" 2>"$TMP/rverr"; then
  if [ -z "$RVRUN" ]; then
    printf '  ok    %s (built for RV32I; not run)\n' "$name"; pass=$((pass+1))
  else
    got=$( cd "$TMP" && perl -e 'alarm 120; exec @ARGV' ./rvrun 8 2>&1 | grep -a -v '^rvrun: ' )
    if [ "$got" = "$EXPECTED" ]; then
      printf '  ok    %s (an unimplemented extern is catchable)\n' "$name"; pass=$((pass+1))
    else
      printf '  FAIL  %s\n    expected: %s\n    got:      %s\n' "$name" "$EXPECTED" "$got"
      fail=$((fail+1)); rc=1
    fi
  fi
else
  printf '  FAIL  %s (-rv refused it)\n' "$name"; head -3 "$TMP/rverr"; fail=$((fail+1)); rc=1
fi

# --- the same corpus, at 64 bits ---------------------------------------------
# rvrun64 is the RV64IM core; the reference stays the C backend, whose int is
# also 64 bits -- so the width-related known-differences of the 32-bit column
# (float_edges, str_edges's big-integer lines, coll_edges) vanish here, and the
# list below is what remains. Same freshness contract in both directions.
KNOWN_DIFF64="graphql_stack_portable map_compact region_growth str_edges"
# graphql_stack_portable   polymorphic == is a word comparison (same as 32)
# map_compact              map_bytes measures an arena that does not exist here
# region_growth            wants more RAM than the sweep gives it (no reclaim)
# str_edges                the prelude's string builders are concat-quadratic and
#                          strbuf is concat-backed: 200k chars = GBs of dead heap.
#                          The fix is a real byte-buffer strbuf, recorded work.
RVRUN64=""
if [ -n "${MEMU:-}" ] && [ -f "$MEMU/riscv-runc/rv64i_run.mere" ]; then
  if "$MERE" -c "$MEMU/riscv-runc/rv64i_run.mere" > "$TMP/rvrun64.c" 2>"$TMP/err" \
     && $CC -O2 -w -o "$TMP/rvrun64" "$TMP/rvrun64.c" 2>"$TMP/err"; then
    RVRUN64="$TMP/rvrun64"
  else
    echo "rv_exec: the RV64 emulator did not build; the 64-bit column did not run"
  fi
fi
pass64=0; fail64=0; known64=0; refused64=0; refused64_names=""
if [ -n "$RVRUN64" ]; then
  for p in "$ROOT"/test/parity/*.mere; do
    name=$(basename "$p" .mere)
    if "$MERE" -c "$p" > "$TMP/ref.c" 2>/dev/null && $CC -O1 -w -o "$TMP/ref" "$TMP/ref.c" 2>/dev/null; then
      ( ulimit -t 60; "$TMP/ref" ) > "$TMP/i.out.raw" 2>&1
      grep -a -v '^()$' "$TMP/i.out.raw" > "$TMP/i.out"
    else continue; fi
    # counted and named, same as the 32-bit sweep: the denominator is the claim
    if ! "$MERE" -rv64 --ram 32 "$p" > "$TMP/prog.bin" 2>/dev/null; then
      refused64=$((refused64+1)); refused64_names="$refused64_names $name"; continue
    fi
    ( cd "$TMP" && perl -e 'alarm 480; exec @ARGV' ./rvrun64 32 2>/dev/null ) | grep -a -v '^rvrun' > "$TMP/r.out"
    sed '$d' "$TMP/i.out" > "$TMP/i.trim"
    expected_diff=no
    for k in $KNOWN_DIFF64; do [ "$k" = "$name" ] && expected_diff=yes; done
    if diff -q "$TMP/i.out" "$TMP/r.out" >/dev/null || diff -q "$TMP/i.trim" "$TMP/r.out" >/dev/null
    then agree=yes; else agree=no; fi
    if [ "$agree" = yes ] && [ "$expected_diff" = yes ]; then
      printf '  FAIL  %s@64 is in KNOWN_DIFF64 but now agrees — remove it\n' "$name"
      fail64=$((fail64 + 1)); rc=1
    elif [ "$agree" = yes ]; then pass64=$((pass64 + 1))
    elif [ "$expected_diff" = yes ]; then known64=$((known64 + 1))
    else
      printf '  FAIL  %s@64 (RV64 disagrees with the C backend)\n' "$name"
      diff -a "$TMP/i.out" "$TMP/r.out" | head -6 | sed 's/^/    /'
      fail64=$((fail64 + 1)); rc=1
    fi
  done
  echo "rv_exec: $pass64 passed, $fail64 failed, $known64 known-different at 64 bits (C backend vs RV64 on the Mere-written CPU)"
  echo "rv_exec: $refused64 of the corpus refused by -rv64 at compile time (not run here; host_matrix names the reasons):"
  echo "$refused64_names" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/^/rv_exec:   /;s/ $//'
  echo ""
fi

# host_read_file: `read_file` / `file_exists` on the hosted target, against the
# C backend. Both sides run IN "$TMP" with the fixtures beside them -- deliberate,
# because the reference otherwise runs in the repo root and the emulator in a temp
# dir, and a relative path would then name two different files (or one that only
# exists on one side, which reads as a backend difference).
#
# The fixtures are made here rather than committed: a NUL-bearing and a
# 20KB file in the tree are awkward, and this way the harness that knows the
# expected content is the thing that wrote it.
name=host_read_file
rfpass=0; rffail=0
printf 'hello from a real file\nsecond line\n' > "$TMP/rv_fixture.txt"
printf 'a\000b\000c' > "$TMP/rv_nul.dat"
: > "$TMP/rv_empty.dat"
{ printf 'START'; i=0; while [ $i -lt 2000 ]; do printf 'xxxxxxxxxx'; i=$((i+1)); done; printf 'END'; } > "$TMP/rv_big.dat"
rm -f "$TMP/rv_absent.txt"
if "$MERE" -c "$ROOT/test/rv/host_read_file.mere" > "$TMP/ref.c" 2>/dev/null \
   && $CC -O1 -w -o "$TMP/ref" "$TMP/ref.c" 2>/dev/null; then
  ( cd "$TMP" && ulimit -t 60; ./ref ) 2>&1 | grep -a -v '^()$' > "$TMP/i.out"
  for width in 32 64; do
    if [ "$width" = 64 ]; then flag=-rv64; emu="$RVRUN64"; else flag=-rv; emu="$RVRUN"; fi
    if ! "$MERE" $flag --ram 16 "$ROOT/test/rv/host_read_file.mere" > "$TMP/prog.bin" 2>"$TMP/rverr"; then
      printf '  FAIL  %s:%s did not build\n' "$name" "$width"; head -2 "$TMP/rverr"; rffail=$((rffail+1)); rc=1; continue
    fi
    if [ -z "$emu" ]; then rfpass=$((rfpass+1)); continue; fi
    ( cd "$TMP" && perl -e 'alarm 120; exec @ARGV' "$emu" 16 2>/dev/null ) | grep -a -v '^rvrun' > "$TMP/r.out"
    if diff -q "$TMP/i.out" "$TMP/r.out" >/dev/null; then
      printf '  ok    %s:%s (a script on disk, NULs, empty, past one chunk, and a catchable miss)\n' "$name" "$width"
      rfpass=$((rfpass+1))
    else
      printf '  FAIL  %s:%s (RV%s disagrees with the C backend)\n' "$name" "$width" "$width"
      diff -a "$TMP/i.out" "$TMP/r.out" | head -8 | sed 's/^/    /'
      rffail=$((rffail+1)); rc=1
    fi
  done
  # --bare must still refuse them: the list `read_file` was on was protecting the
  # machine-only target, and that reason is still good. A lowering that quietly
  # gave --bare a filesystem would be wrong in the permissive direction.
  #
  # The REASON is checked, not just the refusal. The first version of this ran
  # host_read_file.mere under --bare and passed -- on "the program needs a
  # top-level main", because a --bare program must have one. It was reading a
  # refusal it had caused itself and calling it evidence. host_read_file_bare.mere
  # exists to have that main, so the only thing left to refuse is the filesystem.
  if "$MERE" -rv --bare --ram 8 "$ROOT/test/rv/host_read_file_bare.mere" > /dev/null 2>"$TMP/bareerr"; then
    printf '  FAIL  %s:bare — --bare accepted read_file; a machine has no filesystem\n' "$name"
    rffail=$((rffail+1)); rc=1
  elif grep -q "no host filesystem" "$TMP/bareerr"; then
    printf '  ok    %s:bare (refused by name, not by accident)\n' "$name"
    rfpass=$((rfpass+1))
  else
    printf '  FAIL  %s:bare — refused, but for the wrong reason:\n' "$name"
    head -1 "$TMP/bareerr" | sed 's/^/    /'
    rffail=$((rffail+1)); rc=1
  fi
else
  printf '  FAIL  %s: the C reference did not build\n' "$name"; rffail=$((rffail+1)); rc=1
fi
echo "rv_exec: $rfpass passed, $rffail failed for read_file (both widths, and --bare still refuses)"

# host_write_file: the write half, same contract. stdin is piped from a fixture
# THE HARNESS WRITES, and the same bytes go to both sides -- read_stdin drains
# whatever it is given, so feeding the two sides differently would report a
# backend difference that is really a harness difference. Runs in "$TMP" like
# the read gate, because the files it writes must land where the other side's
# read_file will look.
name=host_write_file
wfpass=0; wffail=0
printf 'line1\nline2 for stdin\n' > "$TMP/rv_stdin_fixture"
if "$MERE" -c "$ROOT/test/rv/host_write_file.mere" > "$TMP/ref.c" 2>/dev/null \
   && $CC -O1 -w -o "$TMP/ref" "$TMP/ref.c" 2>/dev/null; then
  ( cd "$TMP" && ulimit -t 60; ./ref < rv_stdin_fixture ) 2>&1 | grep -a -v '^()$' > "$TMP/i.out"
  for width in 32 64; do
    if [ "$width" = 64 ]; then flag=-rv64; emu="$RVRUN64"; else flag=-rv; emu="$RVRUN"; fi
    if ! "$MERE" $flag --ram 16 "$ROOT/test/rv/host_write_file.mere" > "$TMP/prog.bin" 2>"$TMP/rverr"; then
      printf '  FAIL  %s:%s did not build\n' "$name" "$width"; head -2 "$TMP/rverr"; wffail=$((wffail+1)); rc=1; continue
    fi
    if [ -z "$emu" ]; then wfpass=$((wfpass+1)); continue; fi
    ( cd "$TMP" && perl -e 'alarm 120; exec @ARGV' "$emu" 16 < rv_stdin_fixture 2>/dev/null ) | grep -a -v '^rvrun' > "$TMP/r.out"
    if diff -q "$TMP/i.out" "$TMP/r.out" >/dev/null; then
      printf '  ok    %s:%s (roundtrip, truncate, NULs, empty, past one chunk, a catchable miss, stdin)\n' "$name" "$width"
      wfpass=$((wfpass+1))
    else
      printf '  FAIL  %s:%s (RV%s disagrees with the C backend)\n' "$name" "$width" "$width"
      diff -a "$TMP/i.out" "$TMP/r.out" | head -8 | sed 's/^/    /'
      wffail=$((wffail+1)); rc=1
    fi
  done
  # --bare: same protection as read_file, checked for the same right reason
  if "$MERE" -rv --bare --ram 8 "$ROOT/test/rv/host_write_file_bare.mere" > /dev/null 2>"$TMP/bareerr"; then
    printf '  FAIL  %s:bare — --bare accepted write_file; a machine has no filesystem\n' "$name"
    wffail=$((wffail+1)); rc=1
  elif grep -q "no host filesystem" "$TMP/bareerr"; then
    printf '  ok    %s:bare (refused by name, not by accident)\n' "$name"
    wfpass=$((wfpass+1))
  else
    printf '  FAIL  %s:bare — refused, but for the wrong reason:\n' "$name"
    head -1 "$TMP/bareerr" | sed 's/^/    /'
    wffail=$((wffail+1)); rc=1
  fi
else
  printf '  FAIL  %s: the C reference did not build\n' "$name"; wffail=$((wffail+1)); rc=1
fi
echo "rv_exec: $wfpass passed, $wffail failed for write_file/read_stdin (both widths, and --bare still refuses)"


if [ -z "$RVRUN" ]; then
  echo "rv_exec: $pass built, $fail failed — nothing RAN; set MEMU=<memu checkout> for that half"
else
  echo "rv_exec: $pass passed, $fail failed, $known known-different (C backend vs RV32I on the Mere-written CPU)"
  echo "rv_exec: $echoed of those matched except the program's own final value, which only a compiled-in main prints"
  echo "rv_exec: $refused of the corpus refused by -rv at compile time (not run here; host_matrix names the reasons):"
  echo "$refused_names" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/^/rv_exec:   /;s/ $//'
  echo ""
fi
exit $rc
