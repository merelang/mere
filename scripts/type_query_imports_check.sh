#!/bin/sh
# scripts/type_query_imports_check.sh — the type query resolves an import the
# way the build does.
#
# WHY. `mere -t` resolved `import "dep.mere"` against the CURRENT WORKING
# DIRECTORY while `-c` / `-w` / `check` / `fmt` / `fix` / `--decls` all resolved
# it against the FILE'S directory. So a program that builds was rejected by the
# type query, with `cannot resolve path` naming a path nobody wrote. An editor
# is the thing most likely to be on this path and least likely to share a
# working directory with the file, so the failure mode is "only the editor is
# red" -- which reads as the editor being broken.
#
# This is NOT the gate for "-t skips the borrow and capture checks". That one is
# deliberate, documented in `mere --help`, and `-t` legitimately accepts things
# `-c` refuses. What is checked here is narrower and has no oracle problem: the
# same file, asked from a directory that is not its own, must resolve its
# imports on every path that reads it.
#
# Poisoned: the fixture must actually depend on the import (a fixture with
# nothing to resolve would pass on a compiler that resolves nothing), and a
# genuinely missing import must still be refused by both.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "type_query_imports: no compiler at $MERE (run dune build)"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/pkg"
cat > "$tmp/pkg/dep.mere" <<'EOF'
let dep_helper = fn (x: int) -> x + 1;
0
EOF
cat > "$tmp/pkg/main.mere" <<'EOF'
import "dep.mere";
print (str_of_int (dep_helper 1))
EOF

fails=0
# Asked from somewhere that is NOT the file's directory. `cd /` is the point.
ask() { (cd / && "$MERE" $1 "$tmp/pkg/main.mere" >/dev/null 2>"$tmp/err"); }

for path in "-t" "-c" "-w" "check" "--decls"; do
  if ask "$path"; then
    echo "PASS  $path resolves the import from another directory"
  else
    echo "FAIL  $path — $(head -1 "$tmp/err")"
    fails=$((fails + 1))
  fi
done

# POISON 1: the fixture has to depend on the import. Without this a compiler
# that never looked at `import` at all would pass every row above.
rm -f "$tmp/pkg/dep.mere"
caught=0
for path in "-t" "-c"; do
  ask "$path" || caught=$((caught + 1))
done
if [ "$caught" -eq 2 ]; then
  echo "PASS  poison: with the imported file gone, -t and -c both refuse"
else
  echo "FAIL  poison — $((2 - caught)) of 2 accepted a program whose import is missing;"
  echo "      the rows above prove nothing about import resolution."
  fails=$((fails + 1))
fi

# POISON 2: a path that never existed is refused, and the refusal says which
# path it tried -- the diagnostic that named `/dep.mere` is how this was found.
cat > "$tmp/pkg/bad.mere" <<'EOF'
import "no_such_file.mere";
0
EOF
if (cd / && "$MERE" -t "$tmp/pkg/bad.mere" >/dev/null 2>"$tmp/err2"); then
  echo "FAIL  poison — a missing import was accepted"
  fails=$((fails + 1))
elif grep -q 'cannot resolve path' "$tmp/err2" && grep -q "$tmp/pkg" "$tmp/err2"; then
  echo "PASS  poison: a missing import is refused, and the refusal names the directory it tried"
else
  echo "FAIL  poison — refused, but the message does not say where it looked:"
  sed 's/^/      /' "$tmp/err2"
  fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] && { echo "type_query_imports: ok (5 paths + 2 poisons)"; exit 0; }
echo "type_query_imports: $fails failed"; exit 1
