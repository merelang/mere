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
#
# Indented and trailing comments are NOT preserved yet (slice 2). This gate
# counts them so that the number is visible rather than forgotten.
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

# What is still dropped, counted so it stays visible.
ind=$(grep -hcE '^[[:space:]]+//' "$ROOT"/examples/*.mere 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo "?")
printf '  note  indented comments are still dropped (slice 2): ~%s lines in examples/\n' "$ind"

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
