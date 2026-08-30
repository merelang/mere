#!/bin/sh
# scripts/live_query_check.sh — which reads a write affects, checked on every
# backend that can run it.
#
# contrib/state/store.mere already makes the screen a function of the state by
# being COARSE: any write re-runs every watcher. That is always correct and
# never minimal, and it stops at the client -- a read from Postgres is one shot,
# and nothing in contrib/db knows what would stop it being true.
#
# contrib/db/live.mere is the missing derivation, and this holds it to answers
# on mere-blog's real statements.
#
# THE NEGATIVES ARE THE TEST. A module answering YES to everything passes every
# positive case and is worth nothing, because that is what store already does.
# What has to be shown is that a write to `sessions` leaves a read of `posts`
# alone -- 8 of the 45 cases are exactly that, and turning `affects` into a
# constant `true` fails 9 of them. The registry cases go further and assert the
# COUNT: a write must wake exactly the channels it makes stale, so a registry
# that woke everything would fail even though every subscriber got its update.
#
# It also runs on C / LLVM / Wasm, not just the interpreter: the derivation is
# pure string work, so a backend that disagrees about it is a backend that
# would push the wrong updates. An interp-only gate would hide that.
#
# Usage: sh scripts/live_query_check.sh
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
CASES=test/live/derive_cases.mere
[ -x "$MERE" ] || { echo "live_query: no compiler at $MERE (run dune build)"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

ran=0
fail=0

run_interp() {
  "$MERE" "$CASES" > "$tmp/interp.out" 2>&1
  echo $?
}

# interpreter is the reference
rc=$(run_interp)
line=$(grep '^live_derive:' "$tmp/interp.out" | head -1)
[ -n "$line" ] || { echo "live_query: FAIL — interpreter produced no summary"; cat "$tmp/interp.out"; exit 1; }
cases=$(echo "$line" | sed 's/.*: \([0-9]*\) cases.*/\1/')
if [ "${cases:-0}" -lt 45 ]; then
  echo "live_query: FAIL — only ${cases:-0} cases ran; the file declares 45"
  exit 1
fi
if [ "$rc" != "0" ]; then
  echo "live_query: FAIL — interpreter"; grep '^FAIL' "$tmp/interp.out" | sed 's/^/  /'; exit 1
fi
ran=$((ran + 1))
echo "  interp : $line"

# C / LLVM / Wasm: the same answers, or the derivation is not portable
for b in c llvm wasm; do
  case $b in
    c)    flag=-c  ;;
    llvm) flag=-ll ;;
    wasm) flag=-w  ;;
  esac
  if ! "$MERE" $flag "$CASES" > "$tmp/$b.src" 2>"$tmp/$b.err"; then
    echo "  $b : UNSUP ($(head -1 "$tmp/$b.err" | cut -c1-60))"
    continue
  fi
  case $b in
    c|llvm)
      command -v clang >/dev/null 2>&1 || { echo "  $b : SKIP (no clang)"; continue; }
      ext=c; [ $b = llvm ] && ext=ll
      mv "$tmp/$b.src" "$tmp/$b.$ext"
      clang -O1 -o "$tmp/$b.bin" "$tmp/$b.$ext" 2>"$tmp/$b.cc" || {
        echo "  $b : FAIL (emitted code did not compile)"; head -3 "$tmp/$b.cc" | sed 's/^/    /'
        fail=$((fail + 1)); continue; }
      out=$("$tmp/$b.bin" 2>&1); rc=$?
      ;;
    wasm)
      command -v wat2wasm >/dev/null 2>&1 || { echo "  $b : SKIP (no wat2wasm)"; continue; }
      command -v node >/dev/null 2>&1 || { echo "  $b : SKIP (no node)"; continue; }
      wat2wasm --enable-tail-call "$tmp/$b.src" -o "$tmp/$b.wasm" 2>"$tmp/$b.wt" || {
        echo "  $b : FAIL (wat2wasm)"; head -2 "$tmp/$b.wt" | sed 's/^/    /'
        fail=$((fail + 1)); continue; }
      out=$(node scripts/run_wasm.js "$tmp/$b.wasm" 2>&1); rc=$?
      ;;
  esac
  bline=$(echo "$out" | grep '^live_derive:' | head -1)
  if [ "$bline" != "$line" ] || [ "$rc" != "0" ]; then
    echo "  $b : FAIL — $bline (interp said: $line)"
    echo "$out" | grep '^FAIL' | sed 's/^/    /'
    fail=$((fail + 1))
  else
    echo "  $b : $bline"
    ran=$((ran + 1))
  fi
done

if [ "$ran" -lt 2 ]; then
  echo "live_query: FAIL — only $ran backend(s) ran; an interp-only pass hides portability"
  exit 1
fi
[ "$fail" -eq 0 ] || { echo "live_query: FAIL — $fail backend(s) disagree"; exit 1; }
echo "live_query: $cases cases agree on $ran backends"
exit 0
