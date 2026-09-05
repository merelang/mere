#!/bin/sh
# scripts/range_version_check.sh -- the checked loop is the oracle for the
# range-check versioning pass (Q-108, Ast.range_version_program).
#
# The pass rewrites a tail-recursive loop over invariant containers into a guard
# plus an unchecked copy. Its correctness claim is simple to state: with the
# pass on or off, every program prints the same bytes and fails the same way.
# This gate holds it to that on every case in test/range_version/:
#
#   1. the interpreter with the pass ON and OFF agree (stdout, exit status);
#   2. the C and LLVM backends, pass ON and OFF, compiled and run, agree with
#      them (and Wasm too when wat2wasm + node are present);
#   3. the pass planned EXACTLY the loops the case's header names
#      (`// range-version: a,b`, or `none` for a poison case) and dispatched at
#      least one call site for each -- unless `// no-dispatch: a` says that
#      case's call sites are deliberately left alone.
#
# 3 is what makes this a gate on the pass and not only on the program: without
# it, a pass that silently stopped firing would leave every checked loop in
# place and this script would stay green. A case with no header is an error for
# the same reason. fail/*.mere are programs that are SUPPOSED to fail; there the
# comparison is stdout + exit status, and every leg's stderr must name the
# out-of-range index.
#
# Usage: sh scripts/range_version_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "range_version_check: $MERE not found -- run 'dune build'" >&2; exit 1; }
# clang when present: the LLVM leg compiles .ll, which only clang can. Without
# it the C leg still runs with cc and the LLVM leg is skipped, loudly.
if command -v "${CC:-clang}" >/dev/null 2>&1; then CC="${CC:-clang}"; have_ll=1; else CC=cc; have_ll=0; fi
have_wat=0; command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && have_wat=1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; failn=0; checked=0

# `VAR=x run_leg ...` is NOT used anywhere here: in POSIX mode a variable
# assignment before a FUNCTION call stays in effect after it returns (bash 3.2
# as /bin/sh does this), and the first version of this gate switched the pass
# off with exactly that idiom -- for every emit that followed. It then reported
# "planned: none" on every case and would have stayed green forever. The pass
# is toggled through `env` on the command itself.
OFF="env MERE_NO_RANGE_VERSION=1"
run_leg() { # name argv...  -> writes $tmp/$name.out $tmp/$name.rc $tmp/$name.err
  name="$1"; shift
  "$@" >"$tmp/$name.out" 2>"$tmp/$name.err"; echo $? >"$tmp/$name.rc"
}
# A failing program's message reaches stdout on Wasm and stderr elsewhere, and
# the interpreter prefixes it with the path: compare the stdout written BEFORE
# the failure (message lines removed) plus the exit status, and separately
# require every leg to name the out-of-range index somewhere.
visible() { grep -v 'out of bounds' "$tmp/$1.out" | grep -v 'eval error' ; }
same_as_ref() { # leg
  [ "$(cat "$tmp/ref.rc")" = "$(cat "$tmp/$1.rc")" ] || return 1
  if [ "$expect_fail" = 1 ]; then [ "$(visible ref)" = "$(visible "$1")" ]
  else cmp -s "$tmp/ref.out" "$tmp/$1.out"; fi
}

for f in "$ROOT"/test/range_version/*.mere "$ROOT"/test/range_version/fail/*.mere; do
  [ -f "$f" ] || continue
  case_name="$(basename "$f" .mere)"; case "$f" in */fail/*) case_name="fail/$case_name"; expect_fail=1;; *) expect_fail=0;; esac
  checked=$((checked + 1)); problems=""
  header="$(grep -m1 '^// range-version:' "$f" | sed 's|^// range-version: *||' | tr -d ' ')"
  nodispatch="$(grep -m1 '^// no-dispatch:' "$f" | sed 's|^// no-dispatch: *||' | tr -d ' ')"
  [ -n "$header" ] || problems="$problems no-header"
  # 1. interpreter, pass off = the reference
  run_leg ref $OFF "$MERE" "$f"
  run_leg interp_on "$MERE" "$f"
  same_as_ref interp_on || problems="$problems interp(on!=off)"
  if [ $expect_fail = 1 ]; then
    [ "$(cat "$tmp/ref.rc")" != 0 ] || problems="$problems expected-failure-did-not-fail"
  else
    [ "$(cat "$tmp/ref.rc")" = 0 ] || problems="$problems reference-failed:$(head -c 120 "$tmp/ref.err")"
  fi
  # 3. what the pass says it did
  MERE_RANGE_VERSION_LOG=1 "$MERE" -c "$f" >"$tmp/on.c" 2>"$tmp/log" || problems="$problems c-emit(on)"
  planned="$(grep '^range-version: ' "$tmp/log" | grep -v '@call' | sed 's/^range-version: //' | sort | tr '\n' ',' | sed 's/,$//')"
  called="$(grep '^range-version: .* @call$' "$tmp/log" | sed 's/^range-version: //; s/ @call$//' | sort -u | tr '\n' ',' | sed 's/,$//')"
  want="$(echo "$header" | tr ',' '\n' | grep -v '^none$' | sort | tr '\n' ',' | sed 's/,$//')"
  [ "$planned" = "$want" ] || problems="$problems planned=[$planned]!=expected=[$want]"
  for nm in $(echo "$want" | tr ',' ' '); do
    case ",$nodispatch," in *",$nm,"*) continue;; esac
    case ",$called," in *",$nm,"*) ;; *) problems="$problems no-dispatch-for:$nm";; esac
  done
  for nm in $(echo "$nodispatch" | tr ',' ' '); do
    case ",$called," in *",$nm,"*) problems="$problems dispatched-but-header-says-no:$nm";; esac
  done
  # 2. compiled backends, on and off
  $OFF "$MERE" -c "$f" >"$tmp/off.c" 2>/dev/null || problems="$problems c-emit(off)"
  for v in on off; do
    if $CC -O2 -w "$tmp/$v.c" -o "$tmp/c_$v" -lm 2>"$tmp/cc.err"; then
      run_leg "c_$v" "$tmp/c_$v"; same_as_ref "c_$v" || problems="$problems C($v)"
    else problems="$problems C($v)-nocompile"; fi
  done
  if [ $have_ll = 0 ]; then :
  elif "$MERE" -ll "$f" >"$tmp/on.ll" 2>/dev/null && $OFF "$MERE" -ll "$f" >"$tmp/off.ll" 2>/dev/null; then
    for v in on off; do
      if $CC -O2 -w "$tmp/$v.ll" -o "$tmp/ll_$v" -lm 2>"$tmp/cc.err"; then
        run_leg "ll_$v" "$tmp/ll_$v"; same_as_ref "ll_$v" || problems="$problems LLVM($v)"
      else problems="$problems LLVM($v)-nocompile"; fi
    done
  else problems="$problems llvm-emit"; fi
  if [ $have_wat = 1 ]; then
    if "$MERE" -w "$f" >"$tmp/on.wat" 2>/dev/null && $OFF "$MERE" -w "$f" >"$tmp/off.wat" 2>/dev/null; then
      for v in on off; do
        if wat2wasm --enable-tail-call "$tmp/$v.wat" -o "$tmp/$v.wasm" 2>/dev/null; then
          run_leg "w_$v" node "$ROOT/scripts/run_wasm.js" "$tmp/$v.wasm"; same_as_ref "w_$v" || problems="$problems Wasm($v)"
        else problems="$problems Wasm($v)-wat2wasm"; fi
      done
    else problems="$problems wasm-emit"; fi
  fi
  if [ $expect_fail = 1 ]; then
    for leg in ref interp_on c_on c_off ll_on ll_off w_on w_off; do
      [ -f "$tmp/$leg.rc" ] || continue
      cat "$tmp/$leg.out" "$tmp/$leg.err" | grep -q 'out of bounds' || problems="$problems $leg-lacks-message"
    done
  fi
  if [ -z "$problems" ]; then pass=$((pass + 1)); echo "  ok    $case_name  (planned: ${planned:-none}; dispatched: ${called:-none})"
  else
    failn=$((failn + 1)); echo "  FAIL  $case_name :$problems"
    # say why: the leg's exit status, its stderr, and the first lines that differ
    for leg in $problems; do
      l=$(echo "$leg" | sed 's/^LLVM(\(.*\))/ll_\1/; s/^C(\(.*\))/c_\1/; s/-nocompile$//')
      [ -f "$tmp/$l.rc" ] && echo "        $leg: rc=$(cat "$tmp/$l.rc") (ref rc=$(cat "$tmp/ref.rc")) err: $(head -c 240 "$tmp/$l.err" | tr '\n' ' ')"
      [ -f "$tmp/$l.out" ] && diff "$tmp/ref.out" "$tmp/$l.out" 2>/dev/null | head -4 | sed 's/^/        /'
      [ -f "$tmp/cc.err" ] && [ -s "$tmp/cc.err" ] && echo "        cc: $(head -c 240 "$tmp/cc.err" | tr '\n' ' ')"
    done
  fi
done
[ $have_wat = 1 ] || echo "  (wasm leg skipped: wat2wasm or node absent)"
[ $have_ll = 1 ] || echo "  (LLVM leg skipped: clang absent)"
echo "range_version_check: $pass ok, $failn failed, $checked cases"
[ $checked -gt 0 ] || { echo "range_version_check: no cases found -- a gate with nothing to check is not green" >&2; exit 1; }
[ $failn = 0 ]
