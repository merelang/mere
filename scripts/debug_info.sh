#!/bin/sh
# scripts/debug_info.sh — check that a compiled Mere program can be debugged as
# Mere, on the backends that can say so.
#
#   mere -c  -g app.mere   ->  #line directives, read by the C compiler
#   mere -ll -g app.mere   ->  DISubprogram + !dbg metadata, read by LLVM
#
# Both end up in the same place — a DWARF line table naming app.mere — so both
# are checked the same way: compile, then ask `lldb` where a function is. A
# breakpoint that resolves to `app.mere:8` is the evidence; the emitted text
# looking right is not.
#
# Skips (exit 0) when clang or lldb are missing.
#
# Usage:
#   sh scripts/debug_info.sh

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}

for tool in clang lldb; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "debug_info: $tool not found — skipping (this check is optional)"
    exit 0
  fi
done

if [ ! -x "$MERE" ]; then
  echo "debug_info: $MERE not found — run dune build first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/app.mere" <<'EOF'
let twice = fn (n: int) ->
  n * 2;

let thrice = fn (n: int) ->
  n * 3;

let both = fn (n: int) ->
  twice n + thrice n;

let _ = print_int (both 7);
EOF

fail=0

# The two backends name their functions differently — C mangles to `mu_twice`,
# LLVM emits `twice` — so the symbol to break on is the backend's business and
# is passed in.
check_backend() {
  label=$1
  binary=$2
  prefix=$3
  for probe in twice:2 thrice:5 both:8; do
    name=${probe%:*}
    line=${probe#*:}
    got=$(lldb -b -o "b $prefix$name" -o "quit" "$binary" 2>/dev/null \
      | sed -n 's/.*at \(app\.mere:[0-9]*\).*/\1/p' | head -1)
    if [ "$got" = "app.mere:$line" ]; then
      printf '  ok    %-4s %s resolves to %s\n' "$label" "$name" "$got"
    else
      printf '  FAIL  %-4s %s resolved to "%s", expected app.mere:%s\n' \
        "$label" "$name" "$got" "$line" >&2
      fail=1
    fi
  done
}

"$MERE" -c -g "$TMP/app.mere" > "$TMP/app.c"
(cd "$TMP" && clang -g -w -O0 app.c -o app_c)
"$TMP/app_c" > /dev/null
check_backend "C" "$TMP/app_c" "mu_"

"$MERE" -ll -g "$TMP/app.mere" > "$TMP/app.ll"
# The verifier runs here: metadata that does not hang together is an error, not
# a warning, and this is where it would surface.
(cd "$TMP" && clang -g -w -O0 app.ll -o app_ll)
"$TMP/app_ll" > /dev/null
check_backend "LLVM" "$TMP/app_ll" ""

if [ "$fail" = 0 ]; then
  echo "debug_info: ok"
else
  echo "debug_info: FAILED"
fi
exit "$fail"
