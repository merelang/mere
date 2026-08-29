#!/bin/sh
# scripts/mount_check.sh — the router and the manifest come from one list.
#
# An application needs to say how a request is dispatched AND what an endpoint
# is allowed to do. Those were two lists in mere-blog, kept in step by hand,
# and the drift was real enough that a gate got written to compare their
# counts. Checking that two lists agree is worth doing when you have two.
# Having one is better, and contrib/http/mount is that one.
#
# What this holds is not the formatting. It is that neither derivation can
# contain a route the other does not, and that every route carries a
# declaration of what it may do -- so adding an endpoint without saying is not
# something you can forget, it is something you cannot write.
#
# NOT the exit code: `mere <file>` returns 1 whatever the program returns, so a
# gate that trusts $? prints the failures it just read and then reports success.
# htmlbuild_check.sh failed exactly that way until a poison run showed it.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
CASES=test/mount/cases.mere
[ -x "$MERE" ] || { echo "mount: no compiler at $MERE (run dune build)"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

"$MERE" "$CASES" > "$tmp/interp.out" 2>&1
line=$(grep '^mount:' "$tmp/interp.out" | head -1)
[ -n "$line" ] || { echo "mount: FAIL — interpreter produced no summary"; cat "$tmp/interp.out"; exit 1; }
cases=$(echo "$line" | sed 's/.*: \([0-9]*\) cases.*/\1/')
failed=$(echo "$line" | sed 's/.*, \([0-9]*\) failed.*/\1/')
[ "${cases:-0}" -ge 5 ] || { echo "mount: FAIL — only ${cases:-0} cases ran; the file declares 5"; exit 1; }
[ "${failed:-1}" = 0 ] || { echo "mount: FAIL — interpreter, $failed of $cases"; grep -A2 '^FAIL' "$tmp/interp.out" | sed 's/^/  /'; exit 1; }
ran=1
echo "  interp : $line"

for b in c llvm wasm; do
  case $b in c) flag=-c; ext=c ;; llvm) flag=-ll; ext=ll ;; wasm) flag=-w; ext=wat ;; esac
  "$MERE" $flag "$CASES" > "$tmp/b.$ext" 2>"$tmp/b.err" || { echo "  $b : UNSUP ($(head -1 "$tmp/b.err" | cut -c1-56))"; continue; }
  case $b in
    c|llvm)
      command -v clang >/dev/null 2>&1 || { echo "  $b : SKIP (no clang)"; continue; }
      clang -O1 -o "$tmp/b.bin" "$tmp/b.$ext" 2>/dev/null || { echo "  $b : FAIL (emitted code did not compile)"; exit 1; }
      out=$("$tmp/b.bin" 2>&1) ;;
    wasm)
      command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 || { echo "  $b : SKIP (toolchain)"; continue; }
      wat2wasm --enable-tail-call "$tmp/b.wat" -o "$tmp/b.wasm" 2>/dev/null || { echo "  $b : FAIL (wat2wasm)"; exit 1; }
      out=$(node scripts/run_wasm.js "$tmp/b.wasm" 2>&1) ;;
  esac
  bl=$(echo "$out" | grep '^mount:' | head -1)
  [ "$bl" = "$line" ] || { echo "  $b : FAIL — $bl (interp said: $line)"; echo "$out" | grep -A2 '^FAIL' | sed 's/^/    /'; exit 1; }
  echo "  $b : $bl"; ran=$((ran + 1))
done

[ "$ran" -ge 2 ] || { echo "mount: FAIL — only $ran backend ran"; exit 1; }
echo "mount: $cases cases agree on $ran backends"
exit 0
