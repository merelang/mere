#!/bin/sh
# scripts/toplevel_shadow_check.sh — a local `let` may not write a top-level
# binding that happens to share its name.
#
# Q-052. The LLVM backend decided "does this `let` initialise a file-scope
# global?" by asking whether the NAME was in `top_globals_llvm`. A name is not a
# binding: the standard library's own `let n = …` inside `codepoint_of` stored
# into a user's top-level `n`, and a four-line program printed 1 where every
# other backend printed 7. Wrong ANSWERS, silently, on one backend.
#
# ⚠ THE SAME BUG WAS ALREADY FIXED NEXT DOOR. The Wasm backend hit it first --
# a local `let entries` overwrote a KV strbuf pointer and `kv_save` wrote 0
# bytes -- and closed it with `wasm_in_top_level_body`. That fix landed with NO
# GATE, so the twin stayed broken for a month with a probe pinned against it.
# This gate asks BOTH sides, which is the part that was missing.
#
# WHAT IS CHECKED
#   A. behaviour: the four-line program agrees on every backend that runs here
#   B. shape, over the whole corpus: no `@mu_*` global is stored from a function
#      other than `@main`. This is the emit-time footprint of the bug, and it
#      catches a shadowing that no example happens to OBSERVE -- five of the six
#      files that had it still printed the right answer by luck.
#
# Usage:
#   sh scripts/toplevel_shadow_check.sh            # check
#   sh scripts/toplevel_shadow_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "toplevel_shadow: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MODE="${1:-}"
fail=0

# `codepoint_of` is the witness because the collision is with the STANDARD
# LIBRARY: nothing the program imports has to be involved for this to bite.
cat > "$T/p.mere" <<'EOF'
let n = 7;
let f = fn (u: int) -> n;
let _ = print_int (codepoint_of "a");
print_int (f 0)
EOF
WANT=7

# ⚠ THE FIXTURE ONLY MEASURES ANYTHING WHILE THE COLLISION EXISTS. It works
# because `codepoint_of` binds its own `n`; the day that local is renamed this
# file would pass without asking the question. That is not a failure, it is an
# unanswerable run, so it exits 2 and says which name to pick instead.
if ! grep -q 'let n = ' "$ROOT/lib/prelude_stdlib.ml"; then
  echo "toplevel_shadow: the prelude no longer binds a local \`n\` — the fixture's collision is gone; pick a name it still binds" >&2
  exit 2
fi

got=$("$MERE" "$T/p.mere" 2>&1 | tail -1)
if [ "$got" = "$WANT" ]; then
  printf '  ok    %s\n' "interp: a top-level \`n\` survives a callee that binds its own \`n\`"
else
  printf '  FAIL  %s\n' "interp gave \"$got\", wanted $WANT — the fixture is wrong, not the backend"
  fail=1
fi

if command -v "$CC" >/dev/null 2>&1; then
  for pair in "-c c C" "-ll ll LLVM"; do
    set -- $pair
    flag="$1"; ext="$2"; name="$3"
    if "$MERE" "$flag" "$T/p.mere" > "$T/out.$ext" 2>/dev/null \
       && "$CC" -w -O0 -o "$T/bin.$ext" "$T/out.$ext" -lm 2>/dev/null; then
      got=$("$T/bin.$ext" 2>&1 | tail -1)
      if [ "$got" = "$WANT" ]; then
        printf '  ok    %s\n' "$name: same, $WANT"
      else
        printf '  FAIL  %s\n' "$name gave \"$got\", wanted $WANT — a local \`let\` wrote the top-level binding"
        fail=1
      fi
    else
      printf '  note  %s\n' "$name could not be built here"
    fi
  done
else
  printf '  note  %s\n' "no C compiler — only the interpreter was asked"
fi

# ⚠ The twin. The Wasm backend is the one that was fixed first, and a gate that
# only watches the backend it was written for is how this bug survived.
if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 \
   && "$MERE" -w "$T/p.mere" > "$T/p.wat" 2>/dev/null \
   && wat2wasm --enable-tail-call --enable-threads "$T/p.wat" -o "$T/p.wasm" 2>/dev/null; then
  # ⚠ from $ROOT: the host harness loads its sibling .js modules by relative path.
  got=$( ( cd "$ROOT" && node scripts/run_wasm.js "$T/p.wasm" ) 2>/dev/null | tail -1)
  if [ "$got" = "$WANT" ]; then
    printf '  ok    %s\n' "Wasm: same, $WANT (the side that was fixed first stays fixed)"
  else
    printf '  FAIL  %s\n' "Wasm gave \"$got\", wanted $WANT"
    fail=1
  fi
else
  printf '  note  %s\n' "Wasm was not asked (needs wat2wasm and node)"
fi

# --- B: the emit-time footprint, over the corpus ----------------------------
# A store into `@mu_<name>` is the Phase 36 trick that initialises a file-scope
# global at its source-order position. That only ever happens on the top-level
# spine, which is emitted inside `@main`. One anywhere else is a local `let`
# writing somebody else's binding, whether or not the program notices.
SHADOW_CEILING="${SHADOW_CEILING:-0}"
n_files=0; sites=0; names=""
for f in "$ROOT"/examples/*.mere; do
  "$MERE" -ll "$f" > "$T/x.ll" 2>/dev/null || continue
  n_files=$((n_files + 1))
  bad=$(awk '
    /^define /  { fn = $0; sub(/^.*@"?/, "", fn); sub(/"?\(.*$/, "", fn); next }
    /store .*, ptr @mu_/ { if (fn != "main") c++ }
    END { print c + 0 }' "$T/x.ll")
  if [ "$bad" != "0" ]; then
    sites=$((sites + bad)); names="$names $(basename "$f")($bad)"
  fi
done
if [ "$n_files" -lt 200 ]; then
  echo "toplevel_shadow: only $n_files examples emitted LLVM — the corpus is not what this expects" >&2
  exit 2
fi
if [ "$sites" -le "$SHADOW_CEILING" ]; then
  printf '  ok    %s\n' "$n_files examples emitted; $sites globals written outside \`@main\` (ceiling $SHADOW_CEILING)"
else
  printf '  FAIL  %s\n' "$sites globals written outside \`@main\`, above $SHADOW_CEILING:$names"
  fail=1
fi

if [ "$MODE" = "--poison" ]; then
  pfail=0
  # POISON 1: the behavioural direction must be able to see a wrong answer. The
  # poison is the OLD answer, written by hand -- if the fixture cannot tell 1
  # from 7 it is not measuring anything.
  if [ "$WANT" = "1" ]; then
    printf '  FAIL  %s\n' "POISON 1: the fixture's expected value is the broken one"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 1: $WANT and 1 are different answers, so the run can fail"
  fi
  # POISON 2: an impossible ceiling must refuse, which is what says direction B
  # is reading the number it prints.
  if SHADOW_CEILING=-1 sh "$0" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "POISON 2: an impossible ceiling still passed"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 2 (impossible ceiling): direction B can refuse"
  fi
  # POISON 3: ⚠ DIRECTION B COUNTS ZERO NOW, and zero is also what a detector
  # that reads nothing prints. The scanner is fed IR that HAS the bug -- a store
  # into a global from a function that is not `@main` -- and must find exactly
  # one. Without this, a typo in the pattern would read as "fixed forever".
  cat > "$T/fake.ll" <<'FAKE'
define i64 @main() {
entry:
  store i64 7, ptr @mu_n
  ret i64 0
}
define i64 @mu_somewhere_else(i64 %x) {
entry:
  store i64 1, ptr @mu_n
  ret i64 0
}
FAKE
  found=$(awk '
    /^define /  { fn = $0; sub(/^.*@"?/, "", fn); sub(/"?\(.*$/, "", fn); next }
    /store .*, ptr @mu_/ { if (fn != "main") c++ }
    END { print c + 0 }' "$T/fake.ll")
  if [ "$found" = "1" ]; then
    printf '  ok    %s\n' "POISON 3 (IR that has the bug): the scanner finds it, so 0 means 0"
  else
    printf '  FAIL  %s\n' "POISON 3: the scanner found $found in IR built to contain exactly one"
    pfail=1
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "toplevel_shadow --poison: ok (the gate can go red)"
  else
    echo "toplevel_shadow --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "toplevel_shadow: ok"; else echo "toplevel_shadow: FAILED"; fi
exit "$fail"
