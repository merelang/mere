#!/bin/sh
# scripts/codegen_identical.sh — is a refactor really a refactor?
#
# "Behaviour is unchanged" is a claim. This turns it into a check: emit every
# backend's output for EVERY .mere file in the tree with two mere binaries and
# compare byte for byte. A pure refactor produces identical bytes; anything else
# names the file and the backend where it stopped being one.
#
# This is stronger than running the behavioural suites, and for a different
# reason than "more files": parity compares what a few dozen programs PRINT, so
# a change in emitted code that no test's output depends on is invisible to it.
# Byte comparison has no such blind spot -- but it also has no opinion about
# which output is right, so it only answers the refactor question. Run the
# behavioural gates too.
#
# A program the OLD binary refused must be refused by the new one with the same
# message: a refusal is output. A file that neither accepts is agreement.
#
# Usage:
#   sh scripts/codegen_identical.sh <old-mere> [new-mere] [backend...]
#     backends default to: -c -ll -w -rv -rv64
set -u
OLD="${1:?usage: codegen_identical.sh <old-mere> [new-mere] [backend...]}"
shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEW="${1:-$ROOT/_build/default/bin/mere.exe}"
[ $# -gt 0 ] && shift
BACKENDS="${*:--c -ll -w -rv -rv64}"
[ -x "$OLD" ] || { echo "codegen_identical: $OLD not executable" >&2; exit 1; }
[ -x "$NEW" ] || { echo "codegen_identical: $NEW not executable" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -rv64 is `-rv` with the 64-bit width flag; keep the name in the report.
flags_for() {
  case "$1" in
    -rv64) echo "-rv64 --ram 256" ;;
    -rv)   echo "-rv --ram 64" ;;
    *)     echo "$1" ;;
  esac
}

same=0; diff_n=0; both_refused=0; refusal_diff=0; total=0
files=$(find "$ROOT" -name '*.mere' -not -path "$ROOT/_build/*" | sort)
for b in $BACKENDS; do
  fl=$(flags_for "$b")
  for f in $files; do
    total=$((total + 1))
    # shellcheck disable=SC2086
    "$OLD" $fl "$f" >"$TMP/o.out" 2>"$TMP/o.err"; orc=$?
    # shellcheck disable=SC2086
    "$NEW" $fl "$f" >"$TMP/n.out" 2>"$TMP/n.err"; nrc=$?
    if [ "$orc" -ne "$nrc" ]; then
      echo "RC-DIFF   $b ${f#$ROOT/}: old=$orc new=$nrc"
      head -3 "$TMP/o.err" | sed 's/^/    old: /'
      head -3 "$TMP/n.err" | sed 's/^/    new: /'
      refusal_diff=$((refusal_diff + 1)); continue
    fi
    if [ "$orc" -ne 0 ]; then
      if cmp -s "$TMP/o.err" "$TMP/n.err"; then both_refused=$((both_refused + 1))
      else
        echo "MSG-DIFF  $b ${f#$ROOT/}: same exit, different message"
        diff "$TMP/o.err" "$TMP/n.err" | head -6 | sed 's/^/    /'
        refusal_diff=$((refusal_diff + 1))
      fi
      continue
    fi
    if cmp -s "$TMP/o.out" "$TMP/n.out"; then same=$((same + 1))
    else
      echo "CODE-DIFF $b ${f#$ROOT/}"
      diff "$TMP/o.out" "$TMP/n.out" | head -10 | sed 's/^/    /'
      diff_n=$((diff_n + 1))
    fi
  done
done

echo
echo "codegen_identical: $total emissions over backends [$BACKENDS]"
echo "  identical bytes        : $same"
echo "  both refused, same msg : $both_refused"
echo "  CODE-DIFF              : $diff_n"
echo "  refusal changed        : $refusal_diff"
[ $((diff_n + refusal_diff)) -eq 0 ] || { echo "codegen_identical: NOT a pure refactor"; exit 1; }
echo "codegen_identical: byte-identical on every file"
