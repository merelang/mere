#!/bin/sh
# scripts/http_upload_check.sh -- a file upload arrives byte for byte.
#
# contrib/http/multipart.mere was written, documented, and never run. Running it
# found a defect that is not in it: `http_current_body` built the body with
# strlen, so a request body STOPPED AT ITS FIRST ZERO BYTE. Text bodies have
# none, so every JSON test in the project passed while every binary upload would
# have arrived truncated -- a 52-byte file as its first 8 bytes, silently.
#
# CHECKED BY CONTENT, AND THAT MATTERS HERE. The first fix made the reported
# LENGTH correct while the bytes were still wrong, because the checksum function
# used strlen too: the instrument agreed with the bug. So this compares a
# SHA-256 taken by the server against one taken by the shell, and the crypto
# helpers are separately pinned against a NUL-bearing input below.
#
# curl builds the multipart body: the format is its idea of the format, not ours.
#
# Skips (exit 0) without a C compiler or curl.
set -e

MERE=${MERE:-./_build/default/bin/mere.exe}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=${PORT:-18951}

command -v curl >/dev/null 2>&1 || { echo "http_upload_check: no curl -- skipping"; exit 0; }
if ! command -v clang >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
  echo "http_upload_check: no C compiler -- skipping"; exit 0
fi
CC=$(command -v clang || command -v cc)
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA="shasum -a 256"
else echo "http_upload_check: no sha256 tool -- skipping"; exit 0; fi

WORK=$(mktemp -d); SRVPID=""
cleanup() { [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null; rm -rf "$WORK"; :; }
trap cleanup EXIT INT TERM
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

"$MERE" -c "$ROOT/test/http/upload.mere" > "$WORK/u.c"
$CC -O1 -o "$WORK/usrv" "$WORK/u.c" -lm 2>"$WORK/cc.log" \
  || { echo "http_upload_check: link failed -- skipping"; sed -n '1,5p' "$WORK/cc.log"; exit 0; }

# A file that is binary in the way that matters: it starts with a PNG signature
# and then has forty zero bytes and a tail. Anything that stops at a NUL keeps
# the first eight and loses the rest.
perl -e 'print "\x89PNG\r\n\x1a\n"; print "\x00" x 40; print "TAIL"' > "$WORK/bin.dat"
printf 'hello from a text file\n' > "$WORK/t.txt"

MERE_HTTP_PORT="$PORT" "$WORK/usrv" > "$WORK/srv.log" 2>&1 &
SRVPID=$!
k=0
while [ $k -lt 25 ]; do
  curl -sS --max-time 3 -o /dev/null "http://127.0.0.1:$PORT/nope" >/dev/null 2>&1 && break
  k=$((k + 1)); perl -e 'select(undef, undef, undef, 0.4)'
done

want_bin=$($SHA < "$WORK/bin.dat" | awk '{print $1}')
want_txt=$($SHA < "$WORK/t.txt" | awk '{print $1}')

out=$(curl -sS --max-time 10 -F "title=My Post" -F "doc=@$WORK/t.txt" \
        "http://127.0.0.1:$PORT/upload" 2>/dev/null || true)
echo "$out" | grep -q "^title  7 " \
  && ok "a plain form field arrives with its length" \
  || bad "the text field is wrong: [$(echo "$out" | tr '\n' ' ')]"
echo "$out" | grep -q " 23 $want_txt\$" \
  && ok "a text file arrives byte for byte" \
  || bad "the text file differs: [$(echo "$out" | tr '\n' ' ')]"

out=$(curl -sS --max-time 10 -F "img=@$WORK/bin.dat" \
        "http://127.0.0.1:$PORT/upload" 2>/dev/null || true)
echo "$out" | grep -q " 52 " \
  && ok "a 52-byte binary file arrives with all 52 bytes" \
  || bad "the binary file has the wrong length: [$(echo "$out" | tr '\n' ' ')]"
echo "$out" | grep -q " $want_bin\$" \
  && ok "and byte for byte -- the zeroes inside it survived" \
  || bad "the binary content differs (length can still be right): [$(echo "$out" | tr '\n' ' ')]"
kill "$SRVPID" 2>/dev/null || true; SRVPID=""

# The instrument, pinned. sha256_hex used strlen, so it agreed with the bug it
# was supposed to detect. Checked against a reference taken outside Mere.
cat > "$WORK/h.mere" <<'EOF'
extern fn sha256_hex: str -> str;
print (sha256_hex ("ab" ++ chr 0 ++ "cd"))
EOF
"$MERE" -c "$WORK/h.mere" > "$WORK/h.c" && $CC -O1 -o "$WORK/h" "$WORK/h.c" -lm 2>/dev/null
got=$("$WORK/h" | head -1)
want=$(printf 'ab\000cd' | $SHA | awk '{print $1}')
[ "$got" = "$want" ] \
  && ok "sha256_hex hashes a string containing a zero byte, all of it" \
  || bad "sha256_hex stopped at the zero (got $got, wanted $want)"

echo
echo "http_upload_check: $pass passed, $fail failed, of 5 checks"
[ $((pass + fail)) -eq 5 ] || { echo "only $((pass + fail)) of 5 checks ran"; exit 1; }
[ "$fail" -eq 0 ] || exit 1
echo "http_upload_check: ok"
