#!/bin/sh
# scripts/alloc_region_pin.sh — where a function's allocation goes, pinned in
# BOTH directions.
#
# Two functions, one difference: whether the container they allocate appears in
# the RETURN TYPE.
#
#   visible     fn (n: int) -> strbuf_new ()                          : StrBuf[R]
#   invisible   fn (n: int) -> let b = strbuf_new () in strbuf_len b  : int
#
# Called from inside `region R { }`, the first allocates in that block's arena
# and the second in the program-lifetime default region. The reason is that
# generalisation walks the TYPE: a region variable that does not appear there
# is not quantified, so there is no hidden region parameter to bind and the
# allocation falls back to the default.
#
# THE SECOND IS NOT A BUG. It is conservative and it is correct: the level
# discipline distinguishes "allocated and used only inside" from "allocated and
# shared with something that outlives the call", and the TYPE ALONE CANNOT TELL
# THOSE APART. Binding the invisible one to the caller's block would be right
# for the first and a use-after-free for the second.
#
# It is also not free. A renderer whose per-cluster helper returned an `int`
# allocated a StrBuf per cluster into the default region -- about 60 KB per
# frame, 127.8 MB over 2000 frames, growing linearly, with the blocks acquired
# and released correctly the whole time.
#
# So this gate pins the trade rather than either side of it:
#
#   - if the INVISIBLE one starts taking a region parameter, somebody has
#     changed the quantification. That may be the fix -- it is an open
#     question, not a settled one -- but it changes emitted C signatures and it
#     must be a decision, not a side effect. The gate says so and names the
#     note to update.
#   - if the VISIBLE one stops taking one, that is a plain regression: a
#     container a caller can see would be allocated where the caller cannot
#     reclaim it.
#
# Region changes have killed this language before -- three versions shipped
# where a 3D viewer segfaulted on its second frame -- which is why the
# direction nobody intends to change is pinned too.
#
# Usage:  sh scripts/alloc_region_pin.sh

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}
[ -x "$MERE" ] || { echo "alloc_region_pin: $MERE not found — run dune build first" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
checked=0

# The allocation is invisible in the type: `f` returns an int.
cat > "$TMP/invisible.mere" <<'MERE'
let f = fn (n: int) -> let b = strbuf_new () in strbuf_len b;
let _ = region R { f 8 } in 0
MERE

# The allocation is visible: `g` returns the StrBuf itself.
cat > "$TMP/visible.mere" <<'MERE'
let g = fn (n: int) -> strbuf_new ();
let _ = region R { strbuf_len (g 8) } in 0
MERE

"$MERE" -c "$TMP/invisible.mere" > "$TMP/invisible.c" 2>"$TMP/err" || {
  echo "FAIL alloc_region_pin: the invisible case did not compile"; cat "$TMP/err" >&2; exit 1; }
"$MERE" -c "$TMP/visible.mere" > "$TMP/visible.c" 2>"$TMP/err" || {
  echo "FAIL alloc_region_pin: the visible case did not compile"; cat "$TMP/err" >&2; exit 1; }

# --- the invisible one falls back to the default region --------------------
# Its emitted definition takes no region, and the allocation names the default
# one. Both are checked: a signature without a region parameter and a call that
# somehow reached a block arena would mean something stranger than either side
# of this trade.
checked=$((checked + 1))
if ! grep -q '^long long mu_f(long long mu_n) {' "$TMP/invisible.c"; then
  echo "FAIL alloc_region_pin: \`f\` no longer has the signature this pin reads."
  echo "  Expected \`long long mu_f(long long mu_n)\` — a function with NO hidden"
  echo "  region parameter. If quantification changed, that is OPEN QUESTION Q-134"
  echo "  and the note has to be updated deliberately rather than by this gate"
  echo "  going quiet."
  grep -n 'mu_f(' "$TMP/invisible.c" | head -3
  fail=1
fi

checked=$((checked + 1))
if ! grep -q 'mere_strbuf_new((&__lang_default_region))' "$TMP/invisible.c"; then
  echo "FAIL alloc_region_pin: an allocation that does not appear in the function's"
  echo "  type no longer goes to the default region."
  echo "  This is Q-134. It may be the fix; it changes emitted C signatures, so it"
  echo "  is a decision. Update the open question and this gate together, and put"
  echo "  a graphics program in the verification set before believing it: region"
  echo "  changes have shipped three versions that segfaulted one on frame two."
  fail=1
fi

# --- the visible one takes the caller's region ------------------------------
checked=$((checked + 1))
if ! grep -q 'mu_g__int__StrBuf__direct(__lang_region\* __rp[0-9]*, long long mu_n)' "$TMP/visible.c"; then
  echo "FAIL alloc_region_pin: \`g\` no longer takes a hidden region parameter."
  echo "  A container the caller can SEE must be allocated in the caller's arena,"
  echo "  or a \`region R { }\` block cannot reclaim what it asked for. This"
  echo "  direction is a regression, not an open question."
  grep -n 'mu_g__int__StrBuf__direct(' "$TMP/visible.c" | head -3
  fail=1
fi

checked=$((checked + 1))
if ! grep -q 'mere_strbuf_new(__rp[0-9]*)' "$TMP/visible.c"; then
  echo "FAIL alloc_region_pin: \`g\` takes a region but does not allocate in it."
  echo "  The parameter is there and unused, which is worse than not having it:"
  echo "  the signature says the caller's arena and the bytes go elsewhere."
  fail=1
fi

if [ "$fail" = "0" ]; then
  echo "PASS alloc_region_pin: $checked checks — an allocation visible in the type takes the caller's region, one that is not falls back to the default (Q-134, open and conservative)"
  exit 0
fi
exit 1
