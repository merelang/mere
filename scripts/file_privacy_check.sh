#!/bin/sh
# scripts/file_privacy_check.sh — `pub` at the top of a FILE, and the splice it
# has to survive.
#
# `import "x.mere";` splices x's declarations into this one, so after it there
# is a single top-level namespace: a library's helper was as reachable as the
# function it was written for, and nothing could tell a file's surface from its
# insides. `pub` at top level says the file has decided (Q-166).
#
# FOUR DIRECTIONS, and the last two are the ones that keep it usable:
#
#   1. a `pub` binding is callable from a file that imports it;
#   2. an unmarked binding in that same file is NOT;
#   3. a file that marks NOTHING exports everything, as every file written
#      before this does -- opt-in, the way module `pub` is;
#   4. a file that binds the name ITSELF is unaffected by what another file
#      decided about its own copy. The language has one top-level namespace,
#      so two files may bind the same name; without this, one library marking
#      `pub` would make a common name unusable everywhere;
#   5. a LOCAL that happens to share the name -- a parameter, a `let`, a match
#      binder -- is not a reference to anything in another file;
#   6. a name bound at top level by more than ONE file is not checked at all:
#      which binding a reference means is a question this pass cannot answer,
#      and refusing on a guess refuses correct programs.
#
# ⚠ 5 and 6 are here because the first version of this gate did not have them
# and the first version of the feature got both wrong. A module's `pub` keys on
# a QUALIFIED name, which nothing else can spell; a file's keys on the bare one,
# which every local in every file can. Four green directions said nothing about
# it.
#
# Usage:
#   sh scripts/file_privacy_check.sh            # check
#   sh scripts/file_privacy_check.sh --poison   # check that it can go red
#
# THE POISONS are two:
#   1. removing the `pub` marker must make the refused call SUCCEED -- opt-in
#      really is opt-in, and this gate is not just watching a program fail to
#      compile for some other reason;
#   ⚠ 5 and 6 have no poison of their own: their failure mode is the compiler
#   REFUSING, and poison 1 already shows the gate is not passing a tree where
#   everything is refused.
#
#   2. `pub` must still be an ordinary identifier. A file that binds it as a
#      name has to keep working, or the contextual keyword is not contextual.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "file_privacy: $MERE not built" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/p"

cat > "$T/p/lib.mere" <<'EOF'
let internal_helper = fn (n: int) -> n * 7;
pub let public_api = fn (n: int) -> internal_helper n + 1;
EOF
cat > "$T/p/unmarked.mere" <<'EOF'
let helper = fn (n: int) -> n * 2;
let also = fn (n: int) -> helper n;
EOF

fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }

# 1. the public one
printf 'import "lib.mere";\nprint_int (public_api 6)\n' > "$T/p/one.mere"
if [ "$("$MERE" "$T/p/one.mere" 2>/dev/null)" = "43" ]; then
  say ok "a pub binding is callable from the importer"
else
  say FAIL "a pub binding is callable from the importer"; fail=1
fi

# 2. the private one
printf 'import "lib.mere";\nprint_int (internal_helper 6)\n' > "$T/p/two.mere"
out=$("$MERE" "$T/p/two.mere" 2>&1)
case "$out" in
  *"is internal to"*) say ok "an unmarked binding is refused, by name" ;;
  *) say FAIL "an unmarked binding was reachable (got: $(printf '%s' "$out" | head -1))"; fail=1 ;;
esac

# 3. opt-in
printf 'import "unmarked.mere";\nprint_int (helper 21)\n' > "$T/p/three.mere"
if [ "$("$MERE" "$T/p/three.mere" 2>/dev/null)" = "42" ]; then
  say ok "a file that marks nothing exports everything"
else
  say FAIL "a file that marks nothing lost a name"; fail=1
fi

# 4. the importer's own binding of the same name
cat > "$T/p/samename.mere" <<'EOF'
let shared = fn (n: int) -> n * 7;
pub let other = fn (n: int) -> shared n;
EOF
printf 'import "samename.mere";\nlet shared = fn (n: int) -> n + 1;\nprint_int (shared 41)\n' > "$T/p/four.mere"
if [ "$("$MERE" "$T/p/four.mere" 2>/dev/null)" = "42" ]; then
  say ok "a file that binds the name itself is unaffected"
else
  say FAIL "the importer's own binding was refused"; fail=1
fi

# 5. locals that share the name
cat > "$T/p/five.mere" <<'EOF'
import "lib.mere";
let f = fn (n: int) -> let internal_helper = n + 1 in internal_helper * 2;
let g = fn (internal_helper: int) -> internal_helper + 1;
let h = fn (n: int) -> match n with | internal_helper -> internal_helper + 1;
print_int (f 20 + g 0 + h 0)
EOF
if [ "$("$MERE" "$T/p/five.mere" 2>/dev/null)" = "44" ]; then
  say ok "a local with the same name is not a reference to that file"
else
  say FAIL "a local with the same name was refused ($("$MERE" "$T/p/five.mere" 2>&1 | head -1))"
  fail=1
fi

# 6. the same top-level name in two files
cat > "$T/p/marked.mere" <<'EOF'
let common = fn (n: int) -> n * 7;
pub let api2 = fn (n: int) -> common n;
EOF
cat > "$T/p/plain.mere" <<'EOF'
let common = fn (n: int) -> n + 1;
EOF
printf 'import "marked.mere";\nimport "plain.mere";\nprint_int (common 41)\n' > "$T/p/six.mere"
if [ -n "$("$MERE" "$T/p/six.mere" 2>/dev/null)" ]; then
  say ok "a name two files bind is not checked (ambiguous, so not refused)"
else
  say FAIL "an ambiguous name was refused ($("$MERE" "$T/p/six.mere" 2>&1 | head -1))"
  fail=1
fi

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  # POISON 1: without the marker the same call must succeed.
  sed 's/^pub let/let/' "$T/p/lib.mere" > "$T/p/lib2.mere"
  printf 'import "lib2.mere";\nprint_int (internal_helper 6)\n' > "$T/p/p1.mere"
  if [ "$("$MERE" "$T/p/p1.mere" 2>/dev/null)" = "42" ]; then
    say ok "POISON 1 (no marker): the same call succeeds"
  else
    say FAIL "POISON 1: refused even with nothing marked — this gate is watching the wrong failure"
    pfail=1
  fi
  # POISON 2: `pub` is still an identifier.
  printf 'let pub = 7;\nprint_int (pub + 1)\n' > "$T/p/p2.mere"
  if [ "$("$MERE" "$T/p/p2.mere" 2>/dev/null)" = "8" ]; then
    say ok "POISON 2 (pub as a name): still an ordinary identifier"
  else
    say FAIL "POISON 2: binding `pub` stopped working"; pfail=1
  fi
  [ "$pfail" = 0 ] && { echo "file_privacy --poison: ok (the gate can go red)"; exit 0; }
  echo "file_privacy --poison: FAILED"; exit 1
fi

[ "$fail" = 0 ] && { echo "file_privacy: ok"; exit 0; }
echo "file_privacy: FAILED"; exit 1
