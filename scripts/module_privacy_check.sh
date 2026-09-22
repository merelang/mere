#!/bin/sh
# scripts/module_privacy_check.sh — `pub` hides what it does not mark, and
# nothing else.
#
# Three directions, and the third is the one that keeps the feature usable:
#
#   1. a `pub` member is callable from outside;
#   2. an unmarked member of the same module is NOT;
#   3. a module that marks NOTHING exports everything, exactly as it did
#      before `pub` existed — every module written until v0.1.504 is in that
#      state, and making "unmarked" mean private everywhere would have broken
#      all of them.
#
# Usage:
#   sh scripts/module_privacy_check.sh            # check
#   sh scripts/module_privacy_check.sh --poison   # check that it can go red
#
# THE POISONS are two, one per direction:
#   1. removing the `pub` marker must make the call succeed (opt-in really is
#      opt-in, and this gate is not just watching a module fail to compile);
#   2. calling the public member must keep working while the private one is
#      refused — a gate that passed with everything refused would accept a
#      compiler that rejected the whole module.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "module_privacy: $MERE not built" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/module_privacy.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

write() {  # dest marker call
  cat > "$1" <<EOF
module Store {
  let secret_key = fn (n: int) -> n * 7;
  ${2}let get = fn (n: int) -> secret_key n + 1;
}
print_int ($3)
EOF
}

run() { "$MERE" "$1" 2>&1; }
ok_run() { "$MERE" "$1" >/dev/null 2>&1; }

fail=0

write "$tmp/pub_public.mere" "pub " "Store.get 5"
if [ "$(run "$tmp/pub_public.mere")" = "36" ]; then
  printf '  ok    %s\n' "a pub member is callable from outside"
else
  printf '  FAIL  %s (%s)\n' "a pub member is callable from outside" "$(run "$tmp/pub_public.mere" | head -1)"
  fail=1
fi

write "$tmp/pub_private.mere" "pub " "Store.secret_key 5"
msg=$(run "$tmp/pub_private.mere")
if ok_run "$tmp/pub_private.mere"; then
  printf '  FAIL  %s\n' "an unmarked member was callable from outside"
  fail=1
elif printf '%s' "$msg" | grep -q 'internal to module'; then
  printf '  ok    %s\n' "an unmarked member is refused, by name"
else
  printf '  FAIL  %s (%s)\n' "the refusal does not say why" "$(printf '%s' "$msg" | head -1)"
  fail=1
fi

write "$tmp/unmarked.mere" "" "Store.secret_key 5"
if [ "$(run "$tmp/unmarked.mere")" = "35" ]; then
  printf '  ok    %s\n' "a module that marks nothing exports everything"
else
  printf '  FAIL  %s (%s)\n' "a module that marks nothing exports everything" "$(run "$tmp/unmarked.mere" | head -1)"
  fail=1
fi

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  # POISON 1: the same call, with the marker removed, must succeed.
  write "$tmp/p1.mere" "" "Store.secret_key 5"
  if ok_run "$tmp/p1.mere"; then
    printf '  ok    %s\n' "POISON 1 (no marker): the call succeeds"
  else
    printf '  FAIL  %s\n' "POISON 1 (no marker): the call was still refused"
    pfail=1
  fi
  # POISON 2: with the marker, the PUBLIC call must still succeed.
  write "$tmp/p2.mere" "pub " "Store.get 5"
  if ok_run "$tmp/p2.mere"; then
    printf '  ok    %s\n' "POISON 2 (marked module): the public call still works"
  else
    printf '  FAIL  %s\n' "POISON 2: marking anything broke the public call"
    pfail=1
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "module_privacy --poison: ok (both directions hold)"
  else
    echo "module_privacy --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "module_privacy: ok"; else echo "module_privacy: FAILED"; fi
exit "$fail"
