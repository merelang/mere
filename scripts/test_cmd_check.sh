#!/bin/sh
# scripts/test_cmd_check.sh — `mere test` runs what a package declares, in
# order, and says what each exit status means.
#
# Q-169's other half (v0.1.552). `mere test` finds the checks and runs them:
# the `run` list under `[test]` in the nearest mere.toml, and without one the
# directory's verify.sh. Each status is a class -- 0 PASS, 2 CANNOT, 3 SKIP,
# 201 TIMEOUT, else FAIL -- and the command's own exit is 1 on a FAIL or
# TIMEOUT, 2 on a CANNOT, 0 otherwise.
#
# ⚠ THE DECLARED LIST MUST WIN OVER THE CONVENTION. The fixture has both a
# [test] list and a verify.sh that says "fallback"; the poison removes the
# list, and the check that the list ran -- in order -- is what must go red.
#
# Usage:
#   sh scripts/test_cmd_check.sh            # check
#   sh scripts/test_cmd_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "test_cmd: $MERE not built" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MODE="${1:-}"
fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

# a package that declares four checks, one per class, and has a verify.sh too
mkdir -p "$T/pkg/sub"
cat > "$T/pkg/mere.toml" <<'TOML'
[package]
name = "fixture"
version = "0.0.0"

[test]
run = ["sh one.sh", "sh two.sh", "sh three.sh", "sh four.sh"]
TOML
printf 'echo one; echo "MERE_BIN=${MERE_BIN:-unset} MERE=${MERE:-unset}" > seen; exit 0\n' > "$T/pkg/one.sh"
printf 'echo two; exit 3\n' > "$T/pkg/two.sh"
printf 'echo three; exit 2\n' > "$T/pkg/three.sh"
printf 'echo four; exit 1\n' > "$T/pkg/four.sh"
printf 'echo fallback; exit 0\n' > "$T/pkg/verify.sh"
if [ "$MODE" = "--poison" ]; then
  sed -i.bak '/^\[test\]/,$d' "$T/pkg/mere.toml"
fi

out=$(cd "$T/pkg/sub" && "$MERE" test 2>&1); code=$?

# run from a subdirectory: the manifest above it is the package
order=$(printf '%s\n' "$out" | grep -E '^(one|two|three|four|fallback)$' | tr '\n' ' ')
if [ "$order" = "one two three four " ]; then
  ok "the [test] list runs, in order, from a subdirectory of the package"
else
  bad "the declared list did not run in order (saw: $order)"
fi
if printf '%s' "$out" | grep -q '^  PASS (exit 0)  sh one.sh' \
   && printf '%s' "$out" | grep -q '^  SKIP (exit 3)  sh two.sh' \
   && printf '%s' "$out" | grep -q '^  CANNOT (exit 2)  sh three.sh' \
   && printf '%s' "$out" | grep -q '^  FAIL (exit 1)  sh four.sh'; then
  ok "each status is its class: 0 PASS, 3 SKIP, 2 CANNOT, 1 FAIL"
else
  bad "a status was classed wrongly"
fi
[ "$code" -eq 1 ] && ok "a FAIL makes \`mere test\` exit 1" || bad "exit $code with a FAIL in the list"
# ⚠ MERE is the compiler, not the checkout: 12 of the 21 downstream verify.sh
#   files run "$MERE" (the first version passed the checkout, and 14 went red)
grep -q "MERE_BIN=$MERE MERE=$MERE\$" "$T/pkg/seen" 2>/dev/null \
  && ok "the checks see MERE and MERE_BIN, both the compiler that ran them" \
  || bad "MERE_BIN did not reach the check ($(cat "$T/pkg/seen" 2>/dev/null))"

# without a list, verify.sh is the check
mkdir -p "$T/conv"; printf 'echo conv-ran; exit 0\n' > "$T/conv/verify.sh"
out=$(cd "$T/conv" && "$MERE" test 2>&1); code=$?
{ [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '^conv-ran$'; } \
  && ok "no manifest: verify.sh runs, and a pass is exit 0" \
  || bad "the verify.sh convention did not run (exit $code)"

# nothing at all is not a pass
mkdir -p "$T/none"
out=$(cd "$T/none" && "$MERE" test 2>&1); code=$?
{ [ "$code" -eq 2 ] && printf '%s' "$out" | grep -q 'nothing to run'; } \
  && ok "nothing declared and no verify.sh is exit 2, said so" \
  || bad "an empty package was exit $code"

if [ "$fail" -eq 0 ]; then
  [ "$MODE" = "--poison" ] && { echo "test_cmd: POISON NOT CAUGHT -- the list was removed and every check still passed"; exit 1; }
  echo "test_cmd: ok"; exit 0
fi
if [ "$MODE" = "--poison" ]; then
  printf '%s' "$(cd "$T/pkg/sub" && "$MERE" test 2>&1)" | grep -q '^fallback$' \
    || { echo "test_cmd --poison: CAUGHT FOR THE WRONG REASON (the fallback did not run either)"; exit 1; }
  echo "test_cmd --poison: ok (without the list, verify.sh ran and the order check went red)"; exit 0
fi
echo "test_cmd: FAILED"; exit 1
