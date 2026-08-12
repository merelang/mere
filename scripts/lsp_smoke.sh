#!/bin/sh
# scripts/lsp_smoke.sh — drive `mere lsp` the way an editor does.
#
# Feeds a canned session over stdin — initialize, open a file with three syntax
# errors, edit it into a file with one type error, then edit it into a clean one
# — and checks what comes back on stdout.
#
# The point is that the server is exercised through its actual wire format:
# Content-Length framing, JSON-RPC, and the notifications an editor would act on.
# The unit tests cover the handler as a function; this covers the process.
#
# Usage:
#   sh scripts/lsp_smoke.sh
#
# Prerequisites: dune-built _build/default/bin/mere.exe

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}

if [ ! -x "$MERE" ]; then
  echo "lsp_smoke: $MERE not found — run dune build first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

URI="file://$TMP/app.mere"

# One framed message per call: the protocol counts bytes, so the body is written
# to a file and its length measured rather than guessed.
send() {
  printf '%s' "$1" > "$TMP/body"
  printf 'Content-Length: %s\r\n\r\n' "$(wc -c < "$TMP/body" | tr -d ' ')"
  cat "$TMP/body"
}

{
  send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  send '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  # three broken declarations, one of them with an unclosed paren
  send '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"mere","version":1,"text":"let a = fn x -> x +;\nlet b = fn (q: -> q;\nlet c = match with | _ -> 1;\n"}}}'
  # edited into something that parses but does not type-check
  send '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"'"$URI"'","version":2},"contentChanges":[{"text":"let f = fn (n: int) -> n + 1;\nlet _ = print_int (f \"x\");\n"}]}}'
  # and then into something correct
  send '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"'"$URI"'","version":3},"contentChanges":[{"text":"let f = fn (n: int) -> n + 1;\nlet _ = print_int (f 41);\n"}]}}'
  send '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
  send '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$MERE" lsp > "$TMP/out" 2>"$TMP/err"

fail=0

# Occurrences, not matching lines: a message body is followed immediately by the
# next `Content-Length`, with no newline between them — that is the protocol, and
# a line-counting grep sees the two as one line.
expect() {
  what=$1
  pattern=$2
  count=$3
  got=$(grep -o "$pattern" "$TMP/out" | wc -l | tr -d ' ')
  if [ "$got" = "$count" ]; then
    printf '  ok    %s\n' "$what"
  else
    printf '  FAIL  %s (expected %s occurrences of `%s`, got %s)\n' \
      "$what" "$count" "$pattern" "$got"
    fail=1
  fi
}

# Every message is framed, and the three publishes plus two responses are five.
expect "one Content-Length header per message" 'Content-Length:' 5
expect "initialize answers with the server's name" '"serverInfo"' 1
expect "three publishDiagnostics, one per document state" 'publishDiagnostics' 3
expect "the broken file reports all three syntax errors" '"parse error[^"]*".*"parse error[^"]*".*"parse error' 1
expect "the type error is reported once it parses" '"type error' 1
expect "the clean file clears the diagnostics" '"diagnostics":\[\]' 1
# Nothing but protocol on stdout: with the carriage returns and the blank lines
# of the header separator removed, every line must begin a header or a body.
stray=$(tr -d '\r' < "$TMP/out" | grep -vE '^$' | grep -cvE '^(Content-Length:|\{)' || true)
if [ "$stray" = "0" ]; then
  printf '  ok    %s\n' "nothing but protocol on stdout"
else
  printf '  FAIL  %s (%s stray lines)\n' "nothing but protocol on stdout" "$stray"
  fail=1
fi

if [ -s "$TMP/err" ]; then
  printf '  note  stderr was not empty:\n'
  sed 's/^/        /' "$TMP/err"
fi

if [ "$fail" = 0 ]; then
  echo "lsp_smoke: ok"
else
  echo "lsp_smoke: FAILED"
  echo "--- server output ---"
  cat "$TMP/out"
fi
exit "$fail"
