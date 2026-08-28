#!/bin/sh
# scripts/render_agreement_check.sh — the server and the client must build the
# same tree from the same model.
#
# test/render/page.mere holds one pure `page` function. test/render/server.mere
# walks it and serialises directly; test/render/client.mere walks the SAME
# function calling contrib/dom, building real DOM that the headless runner
# dumps. The two are compared as bytes.
#
# WHY THIS IS NOT scripts/parity.sh. parity.sh runs one program on four backends
# and compares stdout, so both sides reach the output the same way. Here the two
# sides reach it by DIFFERENT MECHANISMS — a direct walk versus a sequence of
# createElement / setAttribute / appendChild / set_text calls. That is where a
# server-rendered page and a client-rendered one come apart in practice, and no
# amount of backend parity says anything about it.
#
# NO NORMALISER. The server emits the exact form the headless dump prints. A
# normalising pass between the two is somewhere a real difference gets rubbed
# out, so there isn't one: the comparison is `diff` on raw bytes.
#
# WHAT IT DOES NOT CHECK. Agreement of the two trees, not agreement of HTML
# serialisation (escaping, void elements, attribute quoting) — that is a further
# gate, and saying so because a gate named "render agreement" reads as if it
# covered the whole of rendering.
#
# Skips (exit 0) without wat2wasm or node, the way window_check.sh skips without
# SDL: an external toolchain is not a reason to fail a build.
#
# Usage: sh scripts/render_agreement_check.sh
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
[ -x "$MERE" ] || { echo "render_agreement: no compiler at $MERE (run dune build)"; exit 1; }
command -v wat2wasm >/dev/null 2>&1 || { echo "render_agreement: SKIP (no wat2wasm)"; exit 0; }
command -v node     >/dev/null 2>&1 || { echo "render_agreement: SKIP (no node)"; exit 0; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# --- server: walk the tree and serialise it -------------------------------
if ! "$MERE" test/render/server.mere > "$tmp/server.raw" 2>"$tmp/server.err"; then
  echo "render_agreement: FAIL — server side did not run"; cat "$tmp/server.err"; exit 1
fi
# the interpreter prints the program's unit result on the last line
sed '$d' "$tmp/server.raw" > "$tmp/server.out"

# --- client: walk the same tree building real DOM -------------------------
if ! "$MERE" -w test/render/client.mere > "$tmp/client.wat" 2>"$tmp/client.err"; then
  echo "render_agreement: FAIL — client side did not emit Wasm"; cat "$tmp/client.err"; exit 1
fi
if ! wat2wasm --enable-tail-call "$tmp/client.wat" -o "$tmp/client.wasm" 2>"$tmp/wat.err"; then
  echo "render_agreement: FAIL — emitted Wasm did not assemble"; cat "$tmp/wat.err"; exit 1
fi
if ! node scripts/run_dom_headless.mjs "$tmp/client.wasm" > "$tmp/client.raw" 2>&1; then
  echo "render_agreement: FAIL — client did not run under the headless DOM"
  cat "$tmp/client.raw"; exit 1
fi
# take the #app: section, which is the mounted root
awk '/^#app:$/{on=1;next} /^#/{on=0} on' "$tmp/client.raw" > "$tmp/client.out"

# --- both sides must have produced something ------------------------------
sl=$(wc -l < "$tmp/server.out" | tr -d ' ')
cl=$(wc -l < "$tmp/client.out" | tr -d ' ')
if [ "$sl" -eq 0 ] || [ "$cl" -eq 0 ]; then
  echo "render_agreement: FAIL — a side produced no tree (server $sl lines, client $cl lines)."
  echo "  An empty comparison passes trivially, so this is a failure, not a pass."
  exit 1
fi

if diff -u "$tmp/server.out" "$tmp/client.out" > "$tmp/d" 2>&1; then
  echo "render_agreement: server and client agree on $sl lines of tree"
  exit 0
fi
echo "render_agreement: FAIL — the two sides built different trees"
echo "  (-) what the server serialised, (+) what the client's DOM became"
sed 's/^/  /' "$tmp/d"
exit 1
