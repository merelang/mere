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
# Since v0.1.502 it also drives `textDocument/codeAction`, and drives it the
# whole way: the edit that comes back is APPLIED, and the file has to compile
# afterwards where it did not before. An action whose JSON is well formed and
# whose edit lands in the wrong place is a passing test and a broken feature,
# so the assertion is on the program, not on the message.
#
# Usage:
#   sh scripts/lsp_smoke.sh            # check
#   sh scripts/lsp_smoke.sh --poison   # check that the code-action half can go red
#
# THE POISONS (`--poison`) are two, because the round trip has two halves that
# can lie independently:
#
#   1. apply nothing — the file must STILL fail to compile. A gate that passed
#      here would be measuring a file that was already fine, and would keep
#      passing if the server stopped answering.
#   2. apply the same text at the wrong position — the file must fail. A gate
#      that passed here would be checking that some characters arrived, not that
#      the server said where they go, which is the entire content of a fix.
#
# and a control: the unpoisoned round trip must be green, so that "red" means
# the poison and not a broken harness.

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}

if [ ! -x "$MERE" ]; then
  echo "lsp_smoke: $MERE not found — run dune build first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

POISON=${1:-}

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

# --- the four answers added in v0.1.504 ------------------------------------
#
# document highlight, go to type definition, hover's documentation, and
# signature help. Each is checked for the ANSWER, not for the shape of the
# reply: a handler that returns a well-formed empty list passes a shape test
# and helps nobody.

LS_SRC="$TMP/four.mere"
cat > "$LS_SRC" <<'EOF'
type color = Red | Green;
// Picks a number for a colour.
let pick = fn (c: color) -> match c with | Red -> 1 | Green -> 2;
let add3 = fn (a: int) -> fn (b: int) -> fn (c: int) -> a + b + c;
print_int (add3 (pick Red) (pick Green) 0)
EOF

if python3 - "$LS_SRC" "file://$LS_SRC" "$MERE" <<'PY'
import json, re, subprocess, sys
src_path, uri, mere = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path).read()

def msg(m):
    b = json.dumps(m).encode()
    return b"Content-Length: %d\r\n\r\n" % len(b) + b

def at(i, method, line, ch):
    return msg({"jsonrpc": "2.0", "id": i, "method": method,
                "params": {"textDocument": {"uri": uri},
                           "position": {"line": line, "character": ch}}})

wire = b"".join([
    msg({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}}),
    msg({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    msg({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {
        "uri": uri, "languageId": "mere", "version": 1, "text": src}}}),
    at(2, "textDocument/documentHighlight", 2, 4),   # `pick` at its definition
    at(3, "textDocument/typeDefinition", 4, 22),     # `Red`, whose type is `color`
    at(4, "textDocument/hover", 4, 18),              # a USE of `pick`
    at(5, "textDocument/signatureHelp", 4, 27),      # after add3's first argument
    msg({"jsonrpc": "2.0", "id": 9, "method": "shutdown", "params": None}),
    msg({"jsonrpc": "2.0", "method": "exit", "params": None}),
])
out = subprocess.run([mere, "lsp"], input=wire, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL).stdout.decode("utf8", "replace")
got = {}
for m in re.finditer(r"Content-Length: (\d+)\r\n\r\n", out):
    body = out[m.end():m.end() + int(m.group(1))]
    try:
        d = json.loads(body)
    except Exception:
        continue
    if "id" in d and "result" in d:
        got[d["id"]] = d["result"]

bad = 0
def check(name, cond, detail=""):
    global bad
    if cond:
        print("  ok    %s" % name)
    else:
        print("  FAIL  %s%s" % (name, (" (%s)" % detail) if detail else ""))
        bad = 1

hl = got.get(2) or []
# `pick` is defined once and used twice.
check("documentHighlight finds all three occurrences of `pick`",
      len(hl) == 3, "got %d" % len(hl))
check("documentHighlight marks them as Text (kind 1)",
      all(h.get("kind") == 1 for h in hl))

td = got.get(3)
check("typeDefinition lands on the `color` declaration",
      bool(td) and td["range"]["start"]["line"] == 0,
      json.dumps(td))

hv = got.get(4)
value = (hv or {}).get("contents", {}).get("value", "")
check("hover on a use reports the type", "pick : (color -> int)" in value, value)
check("hover on a use carries the definition's comment",
      "Picks a number for a colour." in value, value)

sh = got.get(5)
check("signatureHelp names the function being called",
      bool(sh) and sh["signatures"][0]["label"].startswith("add3 :"),
      json.dumps(sh))
check("signatureHelp counts the arguments already typed",
      bool(sh) and sh["activeParameter"] == 1,
      json.dumps(sh.get("activeParameter") if sh else None))

sys.exit(bad)
PY
then :; else fail=1; fi

# --- code actions ----------------------------------------------------------
#
# A whole round trip, because every shorter version of this test passes on a
# feature that does not work: ask for the actions at a line whose `match` is
# missing an arm, apply the edit that comes back, and compile the result.
# The assertion is on the program, not on the JSON.

CA_SRC="$TMP/ca.mere"
cat > "$CA_SRC" <<'EOF'
type shape = Circle | Square | Triangle;
let area = fn (s: shape) ->
  match s with
  | Circle -> 1
  | Square -> 2;
print_int (area Circle)
EOF
CA_URI="file://$CA_SRC"

# The session is built where the quoting is safe rather than in the shell: the
# document goes over the wire as a JSON string.
ca_session() {   # -> framed messages on stdout
  python3 - "$CA_SRC" "$CA_URI" <<'PY'
import json, sys
src = open(sys.argv[1]).read()
uri = sys.argv[2]
msgs = [
  {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}},
  {"jsonrpc":"2.0","method":"initialized","params":{}},
  {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
      "uri":uri,"languageId":"mere","version":1,"text":src}}},
  # line 2 (0-based) is the `match`, which is the line the underline is on.
  {"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{
      "textDocument":{"uri":uri},
      "range":{"start":{"line":2,"character":2},"end":{"line":2,"character":2}},
      "context":{"diagnostics":[]}}},
  {"jsonrpc":"2.0","id":3,"method":"shutdown","params":None},
  {"jsonrpc":"2.0","method":"exit","params":None},
]
out = sys.stdout.buffer
for m in msgs:
    body = json.dumps(m).encode()
    out.write(b"Content-Length: %d\r\n\r\n" % len(body))
    out.write(body)
PY
}

# Apply the first action's first edit. `mode` is apply / none / misplace, which
# is what the poisons turn.
ca_apply() {   # server-output mode dest -> exit 3 when no action came back
  python3 - "$1" "$2" "$3" "$CA_SRC" <<'PY'
import json, re, sys
raw = open(sys.argv[1], "rb").read().decode("utf8", "replace")
mode, dest, src_path = sys.argv[2], sys.argv[3], sys.argv[4]
result = None
for m in re.finditer(r"Content-Length: (\d+)\r\n\r\n", raw):
    body = raw[m.end():m.end() + int(m.group(1))]
    try:
        d = json.loads(body)
    except Exception:
        continue
    if d.get("id") == 2:
        result = d.get("result")
if not result:
    print("no code action came back", file=sys.stderr)
    sys.exit(3)
edit = list(result[0]["edit"]["changes"].values())[0][0]
line = edit["range"]["start"]["line"]
char = edit["range"]["start"]["character"]
text = edit["newText"]
if mode == "misplace":
    line, char = 0, 0
lines = open(src_path).read().split("\n")
if mode != "none":
    lines[line] = lines[line][:char] + text + lines[line][char:]
open(dest, "w").write("\n".join(lines))
print(result[0]["title"])
PY
}

ca_round_trip() {  # mode -> compiles / refused / no-action
  ca_session > "$TMP/ca_in"
  "$MERE" lsp < "$TMP/ca_in" > "$TMP/ca_out" 2>"$TMP/ca_err" || true
  if ca_apply "$TMP/ca_out" "$1" "$TMP/ca_after.mere" > "$TMP/ca_title" 2>"$TMP/ca_apply_err"; then
    if "$MERE" check "$TMP/ca_after.mere" >/dev/null 2>&1; then echo compiles; else echo refused; fi
  else
    echo no-action
  fi
}

# The control this whole section rests on: the file must NOT compile as written.
if "$MERE" check "$CA_SRC" >/dev/null 2>&1; then
  printf '  FAIL  %s\n' "the code-action subject compiles before the edit (nothing to fix)"
  fail=1
else
  printf '  ok    %s\n' "the code-action subject does not compile before the edit"
fi

if [ "$POISON" = "--poison" ]; then
  poison_fail=0
  got=$(ca_round_trip apply)
  if [ "$got" = "compiles" ]; then
    printf '  ok    %s\n' "CONTROL: applying the action makes it compile"
  else
    printf '  FAIL  %s (got %s)\n' "CONTROL: applying the action makes it compile" "$got"
    poison_fail=1
  fi
  got=$(ca_round_trip none)
  if [ "$got" = "refused" ]; then
    printf '  ok    %s\n' "POISON 1 (apply nothing): still refused"
  else
    printf '  FAIL  %s (expected refused, got %s)\n' "POISON 1 (apply nothing)" "$got"
    poison_fail=1
  fi
  got=$(ca_round_trip misplace)
  if [ "$got" = "refused" ]; then
    printf '  ok    %s\n' "POISON 2 (edit at the wrong position): refused"
  else
    printf '  FAIL  %s (expected refused, got %s)\n' "POISON 2 (edit at the wrong position)" "$got"
    poison_fail=1
  fi
  if [ "$poison_fail" = 0 ]; then
    echo "lsp_smoke --poison: ok (the gate can go red)"
  else
    echo "lsp_smoke --poison: FAILED"
  fi
  exit "$poison_fail"
fi

got=$(ca_round_trip apply)
if [ "$got" = "compiles" ]; then
  printf '  ok    %s (%s)\n' "the code action's edit makes the file compile" "$(cat "$TMP/ca_title")"
else
  printf '  FAIL  %s (got %s)\n' "the code action's edit makes the file compile" "$got"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "lsp_smoke: ok"
else
  echo "lsp_smoke: FAILED"
  echo "--- server output ---"
  cat "$TMP/out"
fi
exit "$fail"
