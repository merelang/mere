#!/bin/sh
# scripts/lsp_folding_check.sh -- `mere lsp` answers textDocument/foldingRange
# (v0.1.576, Q-147): a top-level declaration that spans lines folds, a run of
# comment lines folds, and a one-line declaration does NOT -- the case that
# would pass if every declaration were folded from where it starts to wherever.
#
# Usage: sh scripts/lsp_folding_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "lsp_folding: $MERE not built" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "lsp_folding: no python3" >&2; exit 2; }
python3 - "$MERE" <<'PY'
import json, subprocess, sys
mere = sys.argv[1]
uri = "file:///tmp/lsp_folding_probe.mere"
text = ("let add = fn (a: int) -> fn (b: int) ->\n"      # 1  } a three-line
        "  let s = a + b in\n"                           # 2  } declaration
        "  s * 2;\n"                                     # 3  }
        "let one = 1;\n"                                 # 4    one line: no fold
        "// a comment that\n"                            # 5  } a comment run
        "// goes on\n"                                   # 6  }
        "print_int (add one 2)\n")                       # 7    the main expression
def frame(o):
    b = json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n" % len(b) + b
msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri, "languageId": "mere", "version": 1, "text": text}}},
        {"jsonrpc": "2.0", "id": 5, "method": "textDocument/foldingRange",
         "params": {"textDocument": {"uri": uri}}},
        {"jsonrpc": "2.0", "id": 99, "method": "shutdown"}, {"jsonrpc": "2.0", "method": "exit"}]
p = subprocess.run([mere, "lsp"], input=b"".join(frame(m) for m in msgs), capture_output=True, timeout=60)
out = p.stdout.decode()
caps_ok = '"foldingRangeProvider":true' in out.replace(" ", "")
got = None
for part in out.split("Content-Length:"):
    i = part.find("{")
    if i < 0: continue
    try: o = json.loads(part[i:])
    except Exception: continue
    if o.get("id") == 5: got = o.get("result")
fail = 0
print(("  ok    " if caps_ok else "  FAIL  ") + "initialize advertises foldingRangeProvider"); fail |= not caps_ok
want = [(0, 2, "region"), (4, 5, "comment")]
have = sorted((r["startLine"], r["endLine"], r.get("kind")) for r in (got or []))
ok = have == want
print(("  ok    " if ok else "  FAIL  ") + "folds %s (want %s: the 3-line declaration and the comment run, not line 4)" % (have, want)); fail |= not ok
print("lsp_folding: FAILED" if fail else "lsp_folding: ok")
sys.exit(1 if fail else 0)
PY
