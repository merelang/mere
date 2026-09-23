#!/bin/sh
# scripts/fmt_comments_check.sh — `mere fmt` does not delete what it was not
# asked to change.
#
# Until v0.1.505 the formatter dropped every comment in the file. That was
# documented as an MVP limitation and it was survivable while nothing else
# depended on comments; v0.1.504 made hover read the block above a definition,
# so one half of the toolchain started reading what the other half deleted.
#
# WHAT IS CHECKED, and what is deliberately not:
#
#   1. a comment in COLUMN 1 survives, and stays above the declaration it was
#      written above (the block hover reads);
#   2. formatting is IDEMPOTENT — a second pass changes nothing, which is what
#      stops comments from drifting a line per run;
#   3. on the examples corpus, the count of column-1 comment lines does not go
#      DOWN. Not "the output equals the input": formatting is allowed to move
#      code. Nothing may be lost.
#   4. on the same corpus, the TOTAL over all three kinds does not fall below a
#      recorded ceiling. Indented comments go back into the run of `let`s they
#      were written in and trailing ones onto the `let` line they were written
#      at (v0.1.511); what is still dropped is a trailing comment on a line the
#      formatter does not emit whole. The ceiling is that number, measured --
#      so the next slice shows up as the number going DOWN, and a regression
#      shows up as it going UP.
#
# ⚠ WHAT IDEMPOTENCE HERE DOES NOT SAY. Check 2 formats ONE fixture twice.
# 109 of the 315 example files are not idempotent under this formatter and were
# not before this gate existed either; that is a separate hole, recorded rather
# than hidden behind a passing check on one file.
#
# Usage:
#   sh scripts/fmt_comments_check.sh            # check
#   sh scripts/fmt_comments_check.sh --poison   # check that it can go red
#
# THE POISONS are two:
#   1. a file whose comments are removed before formatting must show the count
#      DROP — otherwise the counter is not counting comments;
#   2. formatting a file twice must be compared for real: a gate that compared
#      a file with itself would pass on any formatter.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "fmt_comments: $MERE not built" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/fmt_comments.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

col1() { grep -c '^//' "$1" 2>/dev/null || true; }

fail=0

cat > "$tmp/a.mere" <<'EOF'
// MARK_FILE about the file
type color = Red | Green;

// MARK_PICK about pick
let pick = fn (c: color) -> match c with | Red -> 1 | Green -> 2;

// MARK_MAIN before the answer
print_int (pick Red)
EOF

"$MERE" fmt "$tmp/a.mere" > "$tmp/a.out" 2>"$tmp/a.err" || {
  echo "  FAIL  fmt refused the fixture"; sed 's/^/        /' "$tmp/a.err"; exit 1; }

kept=$(grep -c 'MARK_' "$tmp/a.out" || true)
if [ "$kept" = "3" ]; then
  printf '  ok    %s\n' "all three column-1 comments survive"
else
  printf '  FAIL  %s (kept %s of 3)\n' "column-1 comments survive" "$kept"
  fail=1
fi

# Above the declaration, not somewhere else: the line after MARK_PICK must be
# the declaration it was written above.
after=$(grep -A1 'MARK_PICK' "$tmp/a.out" | tail -1)
case "$after" in
  "let pick"*) printf '  ok    %s\n' "the comment stays above its declaration" ;;
  *) printf '  FAIL  %s (next line was: %s)\n' "the comment stays above its declaration" "$after"; fail=1 ;;
esac

"$MERE" fmt "$tmp/a.out" > "$tmp/a.out2" 2>/dev/null || true
if cmp -s "$tmp/a.out" "$tmp/a.out2"; then
  printf '  ok    %s\n' "formatting is idempotent"
else
  printf '  FAIL  %s\n' "a second pass changed the file"
  diff "$tmp/a.out" "$tmp/a.out2" | head -6 | sed 's/^/        /'
  fail=1
fi

# --- the corpus -----------------------------------------------------------
before=0; after_n=0; files=0; skipped=0
for f in "$ROOT"/examples/*.mere; do
  b=$(col1 "$f")
  [ "$b" = "0" ] && continue
  if "$MERE" fmt "$f" > "$tmp/f.out" 2>/dev/null; then
    files=$((files + 1))
    before=$((before + b))
    after_n=$((after_n + $(col1 "$tmp/f.out")))
  else
    skipped=$((skipped + 1))
  fi
done
if [ "$files" -lt 20 ]; then
  echo "fmt_comments: only $files files formatted — the corpus is not what this expects" >&2
  exit 1
fi
if [ "$after_n" -ge "$before" ]; then
  printf '  ok    %s\n' "$files files, $before column-1 comment lines in, $after_n out (none lost)"
else
  printf '  FAIL  %s\n' "$files files: $before column-1 comment lines in, only $after_n out"
  fail=1
fi
[ "$skipped" = "0" ] || printf '  note  %s files were refused by fmt and not counted\n' "$skipped"

# --- the bytes inside a string literal ------------------------------------
# Q-173. The formatter escaped five characters and the lexer writes seven. A
# carriage return went out RAW, the lexer read it as a line break, and
# formatting the output again DROPPED it -- so `mere fmt -i` on a file with
# CRLF in a string (every Redis and HTTP string in contrib) changed what the
# program sends. This is not an idempotence check: it asks whether the bytes
# survive, which is the thing a formatter may never get wrong.
printf 'let s = "a\\r\\nb\\tc\\0d\\\\e\\"f";\nprint_int (str_len s)\n' > "$tmp/bytes.mere"
want=$("$MERE" "$tmp/bytes.mere" 2>/dev/null)
"$MERE" fmt "$tmp/bytes.mere" > "$tmp/bytes1.mere" 2>/dev/null
"$MERE" fmt "$tmp/bytes1.mere" > "$tmp/bytes2.mere" 2>/dev/null
got=$("$MERE" "$tmp/bytes1.mere" 2>/dev/null)
if [ -n "$want" ] && [ "$want" = "$got" ] && cmp -s "$tmp/bytes1.mere" "$tmp/bytes2.mere"; then
  printf '  ok    %s\n' "a string keeps its bytes through fmt (len $want, and twice is the same file)"
else
  printf '  FAIL  %s\n' "a string lost bytes: $want in, $got out (twice-same: $(cmp -s "$tmp/bytes1.mere" "$tmp/bytes2.mere" && echo yes || echo no))"
  fail=1
fi

# --- all three kinds, over the same corpus ---------------------------------
# The ceiling is what was measured when the trailing slice landed. It is a
# CEILING on what may be lost, not a target: shrinking it is the next slice.
LOST_CEILING="${LOST_CEILING:-188}"
all_in=0; all_out=0
for f in "$ROOT"/examples/*.mere; do
  if "$MERE" fmt "$f" > "$tmp/f.out" 2>/dev/null; then
    all_in=$((all_in + $(grep -c '//' "$f" 2>/dev/null || true)))
    all_out=$((all_out + $(grep -c '//' "$tmp/f.out" 2>/dev/null || true)))
  fi
done
lost=$((all_in - all_out))
if [ "$lost" -le "$LOST_CEILING" ]; then
  printf '  ok    %s\n' "all kinds: $all_in comment lines in, $all_out out ($lost lost, ceiling $LOST_CEILING)"
else
  printf '  FAIL  %s\n' "all kinds: $lost lost, above the ceiling of $LOST_CEILING"
  fail=1
fi

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  # POISON 1: strip the comments first — the count must drop.
  grep -v '^//' "$tmp/a.mere" > "$tmp/p1.mere"
  "$MERE" fmt "$tmp/p1.mere" > "$tmp/p1.out" 2>/dev/null || true
  if [ "$(grep -c 'MARK_' "$tmp/p1.out" || true)" = "0" ]; then
    printf '  ok    %s\n' "POISON 1 (comments removed first): none in the output"
  else
    printf '  FAIL  %s\n' "POISON 1: the counter found comments in a file that has none"
    pfail=1
  fi
  # POISON 4: the byte check must notice a lost byte. A formatter that drops
  # the escape is exactly what this file had until v0.1.515, so the poison is
  # the old behaviour: strip one escape from the fixture and the length changes.
  printf 'let s = "a\\r\\nb";\nprint_int (str_len s)\n' > "$tmp/p4a.mere"
  printf 'let s = "a\\nb";\nprint_int (str_len s)\n' > "$tmp/p4b.mere"
  if [ "$("$MERE" "$tmp/p4a.mere" 2>/dev/null)" = "$("$MERE" "$tmp/p4b.mere" 2>/dev/null)" ]; then
    printf '  FAIL  %s\n' "POISON 4: losing the CR did not change the length — the check cannot see it"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 4 (a dropped escape): the length changes, so the check can see it"
  fi
  # POISON 3: the all-kinds ceiling must be able to refuse. A ceiling of -1
  # cannot be met by any formatter, so a run that still passes is not reading
  # the number it prints.
  if LOST_CEILING=-1 sh "$0" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "POISON 3: an impossible ceiling still passed"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 3 (impossible ceiling): the check refuses"
  fi
  # POISON 2: the idempotence check must compare two real runs.
  printf '// MARK_X\nprint_int 1\n' > "$tmp/p2.mere"
  "$MERE" fmt "$tmp/p2.mere" > "$tmp/p2a" 2>/dev/null
  printf '// MARK_Y\nprint_int 1\n' > "$tmp/p2b.mere"
  "$MERE" fmt "$tmp/p2b.mere" > "$tmp/p2b" 2>/dev/null
  if cmp -s "$tmp/p2a" "$tmp/p2b"; then
    printf '  FAIL  %s\n' "POISON 2: two different files formatted identically"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 2: two different files do not compare equal"
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "fmt_comments --poison: ok (the gate can go red)"
  else
    echo "fmt_comments --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "fmt_comments: ok"; else echo "fmt_comments: FAILED"; fi
exit "$fail"
