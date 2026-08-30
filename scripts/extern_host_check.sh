#!/bin/sh
# scripts/extern_host_check.sh — which `extern fn` declarations a native binary
# can actually link.
#
# docs/host-matrix.md answers "does this backend have a lowering" for the 150
# builtins the compiler knows. It says nothing about `extern fn`, which is how
# every contrib module reaches its host -- 34 of them in contrib/dom, 24 in
# contrib/db/pg, 6 in contrib/http, 2 in contrib/http/sse.
#
# Those are not uniform, and the difference is invisible until link time:
#
#   contrib/db/pg      links natively. mere-blog is a native binary talking to
#                      Postgres, so its externs resolve in the C runtime.
#   contrib/http/sse   does NOT. `mere -c` emits a call to sse_broadcast and
#                      the C compiler answers "Undefined symbols". The module's
#                      own header says the Node glue intercepts /sse/<channel>,
#                      which is true and is not written down anywhere a program
#                      can be checked against.
#
# Emitting is not linking, which is the same distance host_matrix.sh had to
# learn between `yes` and `nocompile`. This walks the contrib modules that
# declare externs, compiles a one-line program per module for the C backend,
# and records whether it links.
#
# The point is not to make them all link. contrib/dom is browser-side by
# design. The point is that "this module needs a JS host" should be a recorded
# fact rather than something found by a linker error in an app that already
# chose native.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
EXPECTED=test/extern_host/EXPECTED
[ -x "$MERE" ] || { echo "extern_host: no compiler at $MERE (run dune build)"; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "extern_host: SKIP (no clang)"; exit 0; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

SSL_INC=""; SSL_LIB=""
[ -d /opt/homebrew/opt/openssl@3 ] && SSL_INC="-I/opt/homebrew/opt/openssl@3/include" && SSL_LIB="-L/opt/homebrew/opt/openssl@3/lib"

# One call per module, chosen to be the cheapest extern it declares.
call_for() {
  case $1 in
    http/sse)  echo 'let _ = sse_broadcast "c" "p" in 0' ;;
    dom/dom)   echo 'let _ = dom_set_text (dom_get_by_id "x") "y" in 0' ;;
    db/pg)     echo 'let _ = pg_connect "h" 1 "u" "p" "d" in 0' ;;
    http/http) echo 'let _ = http_set_status 200 in 0' ;;
  esac
}

checked=0
: > "$tmp/out"
for m in http/sse dom/dom db/pg http/http; do
  body=$(call_for "$m")
  [ -n "$body" ] || continue
  printf 'import "contrib/%s.mere";\n%s\n' "$m" "$body" > "$tmp/probe.mere"
  cp "$tmp/probe.mere" ./_extern_probe.mere
  if ! "$MERE" -c ./_extern_probe.mere > "$tmp/p.c" 2>"$tmp/emit.err"; then
    echo "$m emit-refused" >> "$tmp/out"
  elif clang -O0 -w $SSL_INC $SSL_LIB "$tmp/p.c" -lssl -lcrypto -o "$tmp/p.bin" 2>"$tmp/cc.err"; then
    echo "$m links" >> "$tmp/out"
  else
    echo "$m needs-a-js-host" >> "$tmp/out"
  fi
  rm -f ./_extern_probe.mere
  checked=$((checked + 1))
done

[ "$checked" -ge 4 ] || { echo "extern_host: FAIL — probed $checked modules, expected 4"; exit 1; }

if [ "${1:-}" = "--update" ]; then
  { echo "# module  links|needs-a-js-host|emit-refused"
    echo "# Produced by scripts/extern_host_check.sh --update."
    echo "# 'needs-a-js-host' is not a defect; contrib/dom is browser-side by"
    echo "# design. It is a fact an app that chose native has to know BEFORE the"
    echo "# linker tells it."
    cat "$tmp/out"
  } > "$EXPECTED"
  echo "extern_host: wrote $EXPECTED ($checked modules)"; exit 0
fi
[ -f "$EXPECTED" ] || { echo "extern_host: FAIL — no $EXPECTED (run with --update)"; exit 1; }

grep -v '^#' "$EXPECTED" > "$tmp/want"
if diff -u "$tmp/want" "$tmp/out" > "$tmp/d" 2>&1; then
  js=$(grep -c 'needs-a-js-host' "$tmp/out")
  echo "extern_host: $checked modules probed, $js need a JS host (recorded)"
  exit 0
fi
echo "extern_host: FAIL — a module changed which hosts it can run on"
echo "  links -> needs-a-js-host is a regression an app would hit at link time."
echo "  needs-a-js-host -> links means it was fixed; update $EXPECTED."
sed 's/^/  /' "$tmp/d"
exit 1
