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
#     env_var "HOME"            Wasm: ""      interp: Some "/home/you"
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

# --poison: four ways this gate could go quiet, each checked by the MESSAGE it
# should print and not merely by a non-zero exit. A poison that fails for some
# other reason is a poison that passed for the wrong reason.
if [ "${1:-}" = "--poison" ]; then
  fails=0
  run_poison() {
    label=$1; want=$2; shift 2
    out=$(env "$@" sh "$0" 2>&1)
    if [ $? -eq 0 ]; then
      echo "POISON NOT CAUGHT — $label (the gate stayed green)"; fails=$((fails + 1)); return
    fi
    if printf '%s' "$out" | grep -qF "$want"; then
      echo "poison caught: $label"
    else
      echo "POISON CAUGHT FOR THE WRONG REASON — $label"
      echo "  wanted: $want"
      printf '%s\n' "$out" | sed 's/^/  /'
      fails=$((fails + 1))
    fi
  }
  run_poison "a builtin drops out of NAMES" \
    "probed 13 builtins, expected 14" \
    WASM_STUB_NAMES="run env_var file_exists args read_file file_size read_file_bytes read_stdin file_openrw write_file_bytes print_err print_no_nl print_bytes"
  run_poison "the host-surface grep stops matching" \
    "the host surface came back as" \
    SURFACE_FLOOR=99
  run_poison "an unreached import with no reason written down" \
    'no probe reaches host import `exit_proc`' \
    WASM_STUB_UNPROBED="memory mere_spawn mere_join mere_channel_new mere_channel_send mere_channel_recv"
  run_poison "a stale skip: a name listed as unprobed that a probe reaches" \
    'is listed as unprobed but a probe reaches it' \
    WASM_STUB_UNPROBED="memory exit_proc getenv mere_spawn mere_join mere_channel_new mere_channel_send mere_channel_recv"
  [ "$fails" -eq 0 ] && { echo "wasm_stub --poison: 4 caught"; exit 0; }
  echo "wasm_stub --poison: $fails not caught"; exit 1
fi

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
    # `bytes_len` here was a type error -- read_file_bytes answers Vec[R, int],
    # not bytes -- so this probe never emitted and the gate recorded `refused`
    # for it since the day it was written. A probe that cannot compile measures
    # nothing, and `refused` is a word that makes it look like it did.
    read_file_bytes) echo 'if vec_len (read_file_bytes "/etc/hosts") > 0 then "yes" else "no"' ;;
    write_file_bytes) echo "let v = vec_new () in let _ = vec_push v 104 in let _ = vec_push v 105 in let _ = write_file_bytes \"$tmp/wfb.bin\" v in read_file \"$tmp/wfb.bin\"" ;;
    print_err)       echo 'let _ = print_err "E" in "ok"' ;;
    print_no_nl)     echo 'let _ = print_no_nl "AB" in "cd"' ;;
    print_bytes)     echo 'let _ = print_bytes (bytes_of_str "AB") in "cd"' ;;
    # v0.1.528: THE THREE THAT USED TO BE EXCLUDED. The exclusion said their
    # answers "depend on stdin or on writing a file, neither of which is fixed
    # across a run" -- but stdin is fixed by feeding it, and a file is fixed by
    # choosing the path. Both of the stdin ones were stubs, so the two builtins
    # this gate could not see were the two that were broken.
    read_line)       echo 'read_line ()' ;;
    read_stdin)      echo 'read_stdin ()' ;;
    file_openrw)     echo "let f = file_openrw \"$tmp/openrw.bin\" in let n = file_pwrite_bytes f 0 (bytes_of_str \"hi\") in let b = file_pread_bytes f 0 2 in let _ = file_close f in str_of_int n ++ str_of_bytes b" ;;
  esac
}

NAMES="${WASM_STUB_NAMES-run env_var file_exists args read_file file_size read_file_bytes read_line read_stdin file_openrw write_file_bytes print_err print_no_nl print_bytes}"

# Both backends read the same bytes. Without this, `read_line` answers "" on C
# too -- the gate would compare two empty strings and call the stub a host.
printf 'mere_stub_probe_line\nsecond\n' > "$tmp/stdin"

export MERE_STUB_PROBE=set_by_the_gate
checked=0
: > "$tmp/out"
: > "$tmp/reached"
for b in $NAMES; do
  p=$(probe "$b")
  [ -n "$p" ] || continue
  if ! "$MERE" -we "$p" > "$tmp/p.wat" 2>/dev/null; then
    echo "$b refused" >> "$tmp/out"; checked=$((checked + 1)); continue
  fi
  # What this probe reaches, for the denominator below.
  grep -oE '\(import "env" "[A-Za-z_0-9]+"' "$tmp/p.wat" \
    | sed 's/.*"env" "//; s/"//' >> "$tmp/reached"
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
  # Each side gets the same stdin, and file_openrw starts from no file at all --
  # otherwise the second backend reads what the first one wrote and a stub that
  # never opened anything looks like it did.
  rm -f "$tmp/openrw.bin"
  c_out=$("$tmp/p.bin" < "$tmp/stdin" 2>&1 | head -1 | strip_q)
  rm -f "$tmp/openrw.bin"
  w_out=$(node scripts/run_wasm.js "$tmp/p.wasm" < "$tmp/stdin" 2>&1 | head -1 | strip_q)
  if [ "$c_out" = "$w_out" ]; then echo "$b host" >> "$tmp/out"
  else echo "$b stub [C=$c_out Wasm=$w_out]" >> "$tmp/out"; fi
  checked=$((checked + 1))
done

NAME_FLOOR=${NAME_FLOOR-14}
[ "$checked" -ge "$NAME_FLOOR" ] || { echo "wasm_stub: FAIL — probed $checked builtins, expected $NAME_FLOOR"; exit 1; }

# THE DENOMINATOR. "10 builtins probed, 0 stubs" says nothing about the
# eleventh, and the two that were broken were exactly the two a comment had
# excluded. So the gate now states what it is a fraction OF: the Wasm backend's
# host surface, which is the set of `(import "env" ...)` names it can emit --
# every one of them a way for a program to reach outside this module. A name on
# that surface that no probe reaches is either a missing probe or a documented
# reason, and it has to be one of them out loud.
SURFACE_FLOOR=${SURFACE_FLOOR-35}
KNOWN_UNPROBED="${WASM_STUB_UNPROBED-memory exit_proc mere_spawn mere_join mere_channel_new mere_channel_send mere_channel_recv}"
#   memory        not a function -- the module's linear memory, imported as a value
#   exit_proc     the answer is an exit status, not a line of stdout;
#                 scripts/exit_status_check.sh is the gate that compares those
#   mere_spawn / mere_join / mere_channel_*  the answer depends on the
#                 scheduler, so it is not fixed across a run;
#                 test/parity/concurrency_channel.mere holds them instead
grep -oE '\(import \\"env\\" \\"[A-Za-z_0-9]+\\"' lib/codegen_wasm.ml \
  | sed 's/.*env\\" \\"//; s/\\"//' | sort -u > "$tmp/surface"
n_surface=$(wc -l < "$tmp/surface" | tr -d ' ')
[ "$n_surface" -ge "$SURFACE_FLOOR" ] || {
  echo "wasm_stub: FAIL — the host surface came back as $n_surface names (floor $SURFACE_FLOOR)."
  echo "  The emitter's import lines moved and this grep stopped matching them;"
  echo "  an empty surface makes every unprobed name invisible."; exit 1; }
sort -u "$tmp/reached" > "$tmp/reached.u"
comm -23 "$tmp/surface" "$tmp/reached.u" > "$tmp/unreached"
n_unreached=$(wc -l < "$tmp/unreached" | tr -d ' ')
surface_fail=0
while read -r name; do
  [ -n "$name" ] || continue
  case " $KNOWN_UNPROBED " in
    *" $name "*) ;;
    *) echo "wasm_stub: FAIL — no probe reaches host import \`$name\`, and no reason is written down."
       echo "  Add a probe to NAMES, or name it in KNOWN_UNPROBED with why."
       surface_fail=1 ;;
  esac
done < "$tmp/unreached"
# The reverse: a skip that is no longer true. Without this, a name stays on the
# list after a probe starts covering it and the list drifts into fiction.
for name in $KNOWN_UNPROBED; do
  if grep -qx "$name" "$tmp/reached.u"; then
    echo "wasm_stub: FAIL — \`$name\` is listed as unprobed but a probe reaches it. Remove it."
    surface_fail=1
  elif ! grep -qx "$name" "$tmp/surface"; then
    echo "wasm_stub: FAIL — \`$name\` is listed as unprobed but is not on the host surface at all."
    surface_fail=1
  fi
done
[ "$surface_fail" -eq 0 ] || exit 1

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
  echo "  host surface $n_surface imports — $(wc -l < "$tmp/reached.u" | tr -d ' ') reached by a probe, $n_unreached unprobed with a reason ($KNOWN_UNPROBED)"
  exit 0
fi
echo "wasm_stub: FAIL — a builtin changed which side of the host it is on"
echo "  host -> stub is a regression. stub -> host means it was fixed; update $EXPECTED."
sed 's/^/  /' "$tmp/d"
exit 1
