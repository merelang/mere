#!/bin/sh
# scripts/wasm_stub_check.sh — which builtins the Wasm backend answers without
# ever reaching the host.
#
# docs/host-matrix.md records `yes` for a builtin whose backend emitted code.
# scripts/host_matrix.sh's own header explains why that was not enough once
# already: `nocompile` exists because emission succeeded and a C compiler then
# refused the result. This is the same blind spot one level further down --
# emission succeeds, assembly succeeds, the program runs, and the answer is a
# constant.
#
#     run "echo hi"             Wasm: 127     interp: hi
#     env_var "HOME"            Wasm: ""      interp: Some "/Users/284km"
#     file_exists "/etc/hosts"  Wasm: false   interp: true
#
# `file_exists` is the worst of them: it does not fail, it answers "no". A
# caller's `if file_exists p then ... else ...` takes the wrong branch and
# nothing anywhere says why. The C backend runs all three for real, so this is
# not a limitation of compiling Mere -- it is a hole in one backend that the
# table calls `yes`.
#
# HOW IT DETECTS: BY RUNNING IT. Two static attempts came first and both were
# wrong in opposite directions, which is why this one asks the program instead.
#
#   by IMPORTS   the prelude imports the clock whether or not a program reads
#                it, so `time` added none and was called a stub. Too many.
#   by CALL SITES  `env_var` adds calls -- to string formatting -- while never
#                reaching a host function. Too few.
#
# So the probe is compiled for BOTH backends and run, and the answers compared.
# The C backend reaches the host for all of these (checked: `run "echo hi"`
# prints hi, `file_exists "/etc/hosts"` answers 1), so C is the oracle and a
# Wasm answer that differs is a Wasm program that did not do the thing.
#
# That makes the probes have to be deterministic across backends, which is why
# `time` is not among them: two clock reads legitimately differ. What is left
# is the set whose right answer is fixed by the machine this runs on.

set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
EXPECTED=test/wasm_stubs/EXPECTED
[ -x "$MERE" ] || { echo "wasm_stub: no compiler at $MERE (run dune build)"; exit 1; }
for t in clang wat2wasm node; do
  command -v "$t" >/dev/null 2>&1 || { echo "wasm_stub: SKIP (no $t)"; exit 0; }
done

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# NOT the import list. The prelude imports the float / libm / clock set whether
# or not the program uses them, so `time` is in the baseline's imports and a
# program that calls it adds none -- reported as a stub when it is real. What
# separates them is whether the emitted code CALLS a host function it did not
# call before.
host_calls() {
  grep -oE 'call \$(__lang_)?[a-z_0-9]+_?h?\b' "$1" 2>/dev/null | sort -u
}

"$MERE" -we '1 + 1' > "$tmp/base.wat" 2>/dev/null \
  || { echo "wasm_stub: FAIL — the baseline program did not emit"; exit 1; }
host_calls "$tmp/base.wat" > "$tmp/base.txt"
[ -s "$tmp/base.txt" ] || { echo "wasm_stub: FAIL — baseline emitted no host calls; the detector cannot work"; exit 1; }

# One probe per builtin that is supposed to touch the outside world and that the
# matrix records as `yes` for Wasm.
probe() {
  case $1 in
    run)             echo 'run "echo mere_stub_probe"' ;;
    # A str option prints differently on the two backends, so the probe answers
    # with the value itself -- which is what the question is about anyway.
    env_var)         echo 'match env_var "MERE_STUB_PROBE" with Some v -> v | None -> "unset"' ;;
    file_exists)     echo 'if file_exists "/etc/hosts" then "yes" else "no"' ;;
    # A pointer is not an answer: `args ()` prints an address on C. Its length is.
    args)            echo 'show (list_len (args ()))' ;;
    # `show` on both sides: C prints a bool as 1 and Wasm prints it as true, so
    # comparing the raw answers reported a difference that is the printer's, not
    # the program's. The probes must differ only where the backends do.
    read_file)       echo 'if str_len (read_file "/etc/hosts") > 0 then "yes" else "no"' ;;
    file_size)       echo 'if file_size "/etc/hosts" > 0 then "yes" else "no"' ;;
    read_file_bytes) echo 'if bytes_len (read_file_bytes "/etc/hosts") > 0 then "yes" else "no"' ;;
  esac
}

# read_line / read_stdin / file_openrw are left out: their answers depend on
# stdin or on writing a file, neither of which is fixed across a run.
NAMES="run env_var file_exists args read_file file_size read_file_bytes"

export MERE_STUB_PROBE=set_by_the_gate
checked=0
: > "$tmp/out"
for b in $NAMES; do
  p=$(probe "$b")
  [ -n "$p" ] || continue
  if ! "$MERE" -we "$p" > "$tmp/p.wat" 2>/dev/null; then
    echo "$b refused" >> "$tmp/out"; checked=$((checked + 1)); continue
  fi
  if ! "$MERE" -ce "$p" > "$tmp/p.c" 2>/dev/null; then
    echo "$b c-refused" >> "$tmp/out"; checked=$((checked + 1)); continue
  fi
  clang -O1 -w "$tmp/p.c" -o "$tmp/p.bin" 2>/dev/null || {
    echo "$b nocompile" >> "$tmp/out"; checked=$((checked + 1)); continue; }
  wat2wasm --enable-tail-call "$tmp/p.wat" -o "$tmp/p.wasm" 2>/dev/null || {
    echo "$b noassemble" >> "$tmp/out"; checked=$((checked + 1)); continue; }
  # The Wasm host prints a str with its quotes and the C runtime does not. That
  # is the printer disagreeing, not the program, so both sides are stripped of
  # surrounding quotes before comparison -- narrowly, so a real difference in
  # the VALUE still shows.
  strip_q() { sed 's/^"//; s/"$//'; }
  c_out=$("$tmp/p.bin" 2>&1 | head -1 | strip_q)
  w_out=$(node scripts/run_wasm.js "$tmp/p.wasm" 2>&1 | head -1 | strip_q)
  if [ "$c_out" = "$w_out" ]; then echo "$b host" >> "$tmp/out"
  else echo "$b stub [C=$c_out Wasm=$w_out]" >> "$tmp/out"; fi
  checked=$((checked + 1))
done

[ "$checked" -ge 7 ] || { echo "wasm_stub: FAIL — probed $checked builtins, expected 7"; exit 1; }

if [ "${1:-}" = "--update" ]; then
  { echo "# builtin  host|stub|refused — produced by scripts/wasm_stub_check.sh --update"
    echo "# stub = the Wasm backend answers without reaching the host, and"
    echo "#        docs/host-matrix.md records it as \`yes\`."
    cat "$tmp/out"
  } > "$EXPECTED"
  echo "wasm_stub: wrote $EXPECTED ($checked builtins)"; exit 0
fi
[ -f "$EXPECTED" ] || { echo "wasm_stub: FAIL — no $EXPECTED (run with --update)"; exit 1; }

grep -v '^#' "$EXPECTED" > "$tmp/want"
if diff -u "$tmp/want" "$tmp/out" > "$tmp/d" 2>&1; then
  # ' stub$' matched nothing: a stub line carries its evidence after the word,
  # so the anchor never hit and the summary reported 0 while three were recorded
  # right above it. A gate whose headline disagrees with its own file is worse
  # than one with no headline.
  stubs=$(grep -c ' stub' "$tmp/out")
  echo "wasm_stub: $checked builtins probed, $stubs answer without reaching the host (recorded)"
  exit 0
fi
echo "wasm_stub: FAIL — a builtin changed which side of the host it is on"
echo "  host -> stub is a regression. stub -> host means it was fixed; update $EXPECTED."
sed 's/^/  /' "$tmp/d"
exit 1
