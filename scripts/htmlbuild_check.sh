#!/bin/sh
# scripts/htmlbuild_check.sh — the writing half escapes, on every backend.
#
# contrib/http/escape.mere has had html_escape for a long time. mere-blog still
# shipped an index that wrote post titles into markup unescaped, and of six
# examples in this tree that emit HTML, one escapes. The function was never the
# missing piece: the shape of the code let the call be forgotten.
#
# contrib/html/build.mere is a shape with no concatenation to forget, and this
# holds it to the payloads that actually got through -- including the attribute
# case, which is injection with no angle bracket in it and the half that gets
# left out when people escape "the content".
#
# Run on all four backends: escaping is pure string work, so a backend that
# disagrees is one that would serve a different page.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
CASES=test/htmlbuild/cases.mere
[ -x "$MERE" ] || { echo "htmlbuild: no compiler at $MERE (run dune build)"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

"$MERE" "$CASES" > "$tmp/interp.out" 2>&1
rc=$?
line=$(grep '^htmlbuild:' "$tmp/interp.out" | head -1)
[ -n "$line" ] || { echo "htmlbuild: FAIL — interpreter produced no summary"; cat "$tmp/interp.out"; exit 1; }
cases=$(echo "$line" | sed 's/.*: \([0-9]*\) cases.*/\1/')
[ "${cases:-0}" -ge 9 ] || { echo "htmlbuild: FAIL — only ${cases:-0} cases ran; the file declares 9"; exit 1; }
# NOT the exit code. `mere <file>` returns 1 whatever the program returns, so a
# gate that trusts $? reports success while printing the failures it just read.
# This one failed exactly that way, and only a poison run showed it: the summary
# said "2 failed" and the gate exited 0.
failed=$(echo "$line" | sed 's/.*, \([0-9]*\) failed.*/\1/')
[ "${failed:-1}" = 0 ] || { echo "htmlbuild: FAIL — interpreter, $failed of $cases"; grep -A2 '^FAIL' "$tmp/interp.out" | sed 's/^/  /'; exit 1; }
ran=1
echo "  interp : $line"

for b in c llvm wasm; do
  case $b in c) flag=-c; ext=c ;; llvm) flag=-ll; ext=ll ;; wasm) flag=-w; ext=wat ;; esac
  "$MERE" $flag "$CASES" > "$tmp/b.$ext" 2>"$tmp/b.err" || { echo "  $b : UNSUP ($(head -1 "$tmp/b.err" | cut -c1-56))"; continue; }
  case $b in
    c|llvm)
      command -v clang >/dev/null 2>&1 || { echo "  $b : SKIP (no clang)"; continue; }
      clang -O1 -o "$tmp/b.bin" "$tmp/b.$ext" 2>"$tmp/cc" || { echo "  $b : FAIL (emitted code did not compile)"; exit 1; }
      out=$("$tmp/b.bin" 2>&1) ;;
    wasm)
      command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 || { echo "  $b : SKIP (toolchain)"; continue; }
      wat2wasm --enable-tail-call "$tmp/b.wat" -o "$tmp/b.wasm" 2>/dev/null || { echo "  $b : FAIL (wat2wasm)"; exit 1; }
      out=$(node scripts/run_wasm.js "$tmp/b.wasm" 2>&1) ;;
  esac
  bl=$(echo "$out" | grep '^htmlbuild:' | head -1)
  if [ "$bl" != "$line" ]; then
    echo "  $b : FAIL — $bl (interp said: $line)"; echo "$out" | grep -A2 '^FAIL' | sed 's/^/    /'; exit 1
  fi
  echo "  $b : $bl"; ran=$((ran + 1))
done

[ "$ran" -ge 2 ] || { echo "htmlbuild: FAIL — only $ran backend ran"; exit 1; }
echo "htmlbuild: $cases cases agree on $ran backends"
exit 0
