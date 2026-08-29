#!/bin/sh
# scripts/nojs_check.sh — G-7: the primary flow completes with no JavaScript.
#
# The code arrives over the network on every visit, and sometimes it does not:
# a bad connection, a proxy, an extension, or simply slowness. An app whose
# forms work as HTML degrades when delivery fails; one with no fallback fails
# totally. That is partial-failure engineering, and like any other claim about
# failure it is worth nothing unless something exercises it.
#
# curl runs no JavaScript by construction, so this IS a browser with scripting
# off.
#
# THE REQUEST IS READ OUT OF THE PAGE. The method, the action and the field
# names are parsed from the <form> the server rendered, and the POST is built
# from them. A request written into this script would pass against a page whose
# form is broken, renders no form at all, or names fields the handler does not
# read -- which is exactly what is being checked.
#
# Checked, in order: the page carries a form with a method and an action; the
# form's own submission is accepted; the effect is visible on a subsequent GET
# (so the flow completed, not just returned 200); a submission missing a
# required field is refused rather than silently accepted; and the success path
# answers 303 with a Location, because a browser with no script reloads into a
# resubmission otherwise.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
PORT=${PORT:-8097}
SRC=examples/nojs/server.mere
[ -x "$MERE" ] || { echo "nojs: no compiler at $MERE (run dune build)"; exit 1; }
for t in wat2wasm node curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "nojs: SKIP (no $t)"; exit 0; }
done

tmp=$(mktemp -d) || exit 1
srv=""
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

"$MERE" -w "$SRC" > "$tmp/s.wat" 2>"$tmp/e" || { echo "nojs: FAIL — no Wasm"; head -4 "$tmp/e"; exit 1; }
wat2wasm --enable-tail-call "$tmp/s.wat" -o "$tmp/s.wasm" 2>"$tmp/w" || {
  echo "nojs: FAIL — wat2wasm"; head -3 "$tmp/w"; exit 1; }

node scripts/run_http_server.js "$tmp/s.wasm" > "$tmp/srv.log" 2>&1 &
srv=$!
i=0
until curl -s -m 1 "http://127.0.0.1:$PORT/" > "$tmp/page.html" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "nojs: FAIL — server never answered"; cat "$tmp/srv.log"; exit 1; }
  sleep 0.3
done

fail=0; checks=0
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
note() { checks=$((checks + 1)); }

# ---- read the form out of the page --------------------------------------
form=$(tr -d '\n' < "$tmp/page.html" | sed -n 's/.*<form\([^>]*\)>.*/\1/p')
note
[ -n "$form" ] || bad "the page renders no <form>: with scripting off there is nothing to submit"

method=$(echo "$form" | sed -n 's/.*method="\([^"]*\)".*/\1/p' | tr 'a-z' 'A-Z')
action=$(echo "$form" | sed -n 's/.*action="\([^"]*\)".*/\1/p')
note; [ "$method" = "POST" ] || bad "the form declares method [$method]; a write over GET is not a submission"
note; [ -n "$action" ] || bad "the form has no action, so it submits to itself by accident rather than by design"

# Nothing after this point can run without a method and an action to submit
# with. Carrying on would feed curl an empty -X and report its complaint as if
# it were a finding about the page.
if [ "$method" != "POST" ] || [ -z "$action" ]; then
  echo "nojs: FAIL — the page does not describe a submission a scriptless client could make ($fail of $checks so far)"
  exit 1
fi

fields=$(tr -d '\n' < "$tmp/page.html" | grep -oE '<input[^>]*name="[^"]*"' | sed -n 's/.*name="\([^"]*\)".*/\1/p')
nfields=$(echo "$fields" | grep -c .)
note; [ "${nfields:-0}" -ge 2 ] || bad "the form exposes ${nfields:-0} named fields; nothing to fill in"

# build the body from what the form declared, not from this script
body=""
for f in $fields; do
  body="${body}${body:+&}${f}=nojs-$f"
done

# ---- submit it the way the markup says -----------------------------------
code=$(curl -s -o "$tmp/post.out" -w '%{http_code}' -m 5 \
        -X "$method" --data "$body" "http://127.0.0.1:$PORT$action")
note
case "$code" in
  303|302) ;;
  200) bad "the submission answered 200; with no script, a reload resubmits it. POST/redirect/GET is the mechanism that prevents that" ;;
  *)   bad "the form's own submission answered $code" ;;
esac

loc=$(curl -s -D - -o /dev/null -m 5 -X "$method" --data "${body}-2" \
        "http://127.0.0.1:$PORT$action" | sed -n 's/^[Ll]ocation: *//p' | tr -d '\r')
note; [ -n "$loc" ] || bad "the redirect carries no Location, so there is nowhere to go without a script"

# ---- the effect must be visible on a plain GET ---------------------------
curl -s -m 5 "http://127.0.0.1:$PORT/" > "$tmp/after.html"
note
grep -q 'nojs-author' "$tmp/after.html" \
  || bad "the entry does not appear on a subsequent GET: the flow returned, but did not complete"

# ---- and an invalid submission must be refused, in HTML ------------------
code2=$(curl -s -o "$tmp/bad.out" -w '%{http_code}' -m 5 -X "$method" --data "author=&body=" \
         "http://127.0.0.1:$PORT$action")
note; [ "$code2" = "422" ] || bad "an empty submission answered $code2 rather than being refused"
note
grep -qi '<form' "$tmp/bad.out" \
  || bad "the refusal is not a page with the form on it, so a scriptless client has nowhere to correct it"

[ "$checks" -ge 9 ] || { echo "nojs: FAIL — only $checks checks ran"; exit 1; }
[ "$fail" -eq 0 ] || { echo "nojs: FAIL — $fail of $checks"; exit 1; }
echo "nojs: $checks checks — form read from the page ($nfields fields), submitted, and the effect was visible with no JavaScript"
exit 0
