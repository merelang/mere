#!/bin/sh
# scripts/lsp_binding_position_check.sh — go to definition and rename point at
# the NAME, in every form that binds one.
#
# WHY. `Top_let`'s binder is a pattern and has always carried a position.
# `Top_let_rec`'s was a bare string, so everything that needed to point at the
# name pointed at the VALUE instead -- a different line as soon as the `fn` is
# written under the `=`, which is how most of mere-ruby's ~2,500 top-level
# functions are written. Rename was worse than off-by-a-line: the declaration
# was not an occurrence at all, so it rewrote every USE and left the definition
# alone, handing the author a program that no longer compiles.
#
# ⚠ EVERY FIXTURE PUTS THE VALUE ON THE NEXT LINE. Written on one line, the
# name's position and the value's differ by a few columns, and a check that
# compares lines passes either way. The gate asserts that separation about
# itself before it trusts any of its own rows (poison 1).
#
# Driven through the real server over JSON-RPC, because the thing that was
# broken is what an editor receives.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "lsp_binding_position: no compiler at $MERE" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "lsp_binding_position: SKIP (no python3)"; exit 0; }

MERE="$MERE" python3 - "${1:-}" <<'PY'
import json, os, re, subprocess, sys

MERE = os.environ["MERE"]
POISON = sys.argv[1] == "--poison" if len(sys.argv) > 1 else False

def frame(o):
    b = json.dumps(o).encode()
    return b"Content-Length: %d\r\n\r\n" % len(b) + b

def serve(text, line, col, new_name="RENAMED"):
    uri = "file:///tmp/lsp_binding_position.mere"
    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"rootUri": None, "capabilities": {}}},
        {"jsonrpc": "2.0", "method": "initialized", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri, "languageId": "mere",
                                     "version": 1, "text": text}}},
        {"jsonrpc": "2.0", "id": 2, "method": "textDocument/definition",
         "params": {"textDocument": {"uri": uri},
                    "position": {"line": line, "character": col}}},
        {"jsonrpc": "2.0", "id": 3, "method": "textDocument/rename",
         "params": {"textDocument": {"uri": uri},
                    "position": {"line": line, "character": col},
                    "newName": new_name}},
        {"jsonrpc": "2.0", "id": 9, "method": "shutdown", "params": {}},
    ]
    p = subprocess.run([MERE, "lsp"], input=b"".join(frame(m) for m in msgs),
                       capture_output=True, timeout=120)
    out = p.stdout.decode(errors="replace")
    got = {}
    for m in re.finditer(r"Content-Length: (\d+)\r\n\r\n", out):
        try:
            o = json.loads(out[m.end():m.end() + int(m.group(1))])
        except Exception:
            continue
        if o.get("id") in (2, 3):
            got[o["id"]] = o.get("result")
    edits = (got.get(3) or {}).get("changes", {}).get(uri, [])
    return got.get(2), edits

def text_at(text, rng):
    return text.split("\n")[rng["start"]["line"]][
        rng["start"]["character"]:rng["end"]["character"]]

# name, source, (line, col) of a USE, the name it should resolve to,
# and how many places a rename must touch.
CASES = [
    ("top-level let",
     "let twice =\n  fn (n: int) -> n * 2;\nlet helper =\n  fn (n: int) -> twice n + 1;\nprint_int (helper 3)\n",
     3, 18, "twice", 2),
    ("top-level let rec (first member)",
     "let rec twice =\n  fn (n: int) -> n * 2\nand helper =\n  fn (n: int) -> twice n + 1;\nprint_int (helper 3)\n",
     3, 18, "twice", 2),
    ("an `and` member",
     "let rec first =\n  fn (n: int) -> n\nand second =\n  fn (n: int) -> n + 1;\nprint_int (first (second 1))\n",
     4, 18, "second", 2),
    ("local let",
     "let f = fn (n: int) ->\n  let base =\n    41\n  in base + n;\nprint_int (f 1)\n",
     3, 6, "base", 2),
    ("local let rec",
     "let f = fn (n: int) ->\n  let rec loop =\n    fn (i: int) -> if i <= 0 then 0 else loop (i - 1)\n  in loop n;\nprint_int (f 3)\n",
     3, 6, "loop", 3),
]

fails = 0

# POISON 1: the fixtures have to separate the binder's line from the value's.
# A one-line fixture cannot tell the two positions apart, and every row below
# would pass on the compiler this gate exists to catch.
for label, src, _, _, name, _ in CASES:
    lines = src.split("\n")
    binder = next(i for i, l in enumerate(lines) if re.search(r'\b' + name + r'\s*=\s*$', l))
    value = binder + 1
    if not lines[value].strip():
        print(f"FAIL  fixture `{label}` has nothing on the line after the binder")
        fails += 1

for label, src, line, col, name, want_edits in CASES:
    if POISON and label == "top-level let rec (first member)":
        # POISON 2: ask about a name that is not there. A gate that reports
        # whatever came back would call this a pass.
        name = "no_such_name"
    d, edits = serve(src, line, col)
    if d is None:
        print(f"FAIL  {label}: no definition answered")
        fails += 1
        continue
    got = text_at(src, d["range"])
    if got == name:
        print(f"PASS  {label}: definition lands on `{name}`")
    else:
        print(f"FAIL  {label}: definition lands on `{got}`, wanted `{name}`")
        fails += 1
    bad = [text_at(src, e["range"]) for e in edits if text_at(src, e["range"]) != name]
    if len(edits) == want_edits and not bad:
        print(f"PASS  {label}: rename touches {want_edits} places, all of them `{name}`")
    else:
        print(f"FAIL  {label}: rename touched {len(edits)} place(s) (wanted {want_edits})"
              + (f", including {bad}" if bad else "")
              + " — a rename that misses the declaration leaves a program that does not compile")
        fails += 1

if POISON:
    if fails:
        print("lsp_binding_position --poison: caught")
        sys.exit(0)
    print("POISON NOT CAUGHT — the gate stayed green with a name that is not in the file")
    sys.exit(1)

if fails:
    print(f"lsp_binding_position: {fails} failed")
    sys.exit(1)
print(f"lsp_binding_position: ok ({len(CASES)} binding forms, definition + rename)")
PY
