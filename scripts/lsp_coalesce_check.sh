#!/bin/sh
# scripts/lsp_coalesce_check.sh -- keystrokes that are already out of date are
# not each re-checked (v0.1.576, Q-023).
#
# A didChange carries the whole document and every one re-checks the program --
# 10.5 s a time on mere-ruby's main.mere -- and `mere lsp` handled them one by
# one, so N keystrokes queued N checks. An unbroken run of didChanges for one
# document that has already arrived is now handled as its last.
#
#   burst     open + 10 changes sent at once        -> 2 publishes, not 11
#   between   change, hover, change sent at once    -> both changes checked: a
#             request is answered against the text it was asked about
#   paced     the same 10 changes 0.3 s apart       -> 11 publishes: the control,
#             without which "2" could mean the counter is broken
#
# Usage: sh scripts/lsp_coalesce_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "lsp_coalesce: $MERE not built" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "lsp_coalesce: no python3" >&2; exit 2; }
python3 - "$MERE" <<'PY'
import json, subprocess, sys, time
mere = sys.argv[1]
uri = "file:///tmp/lsp_coalesce_probe.mere"
def frame(o):
    b = json.dumps(o).encode()
    return b"Content-Length: %d\r\n\r\n" % len(b) + b
def change(n):
    return {"jsonrpc": "2.0", "method": "textDocument/didChange",
            "params": {"textDocument": {"uri": uri, "version": n},
                       "contentChanges": [{"text": "let x = %d;\nprint_int x\n" % n}]}}
init = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "initialized", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri, "languageId": "mere", "version": 0,
                                     "text": "let x = 0;\nprint_int x\n"}}}]
end = [{"jsonrpc": "2.0", "id": 99, "method": "shutdown"}, {"jsonrpc": "2.0", "method": "exit"}]
hover = {"jsonrpc": "2.0", "id": 7, "method": "textDocument/hover",
         "params": {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 4}}}
def session(msgs, gap=0.0):
    p = subprocess.Popen([mere, "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    if gap == 0.0:
        p.stdin.write(b"".join(frame(m) for m in msgs)); p.stdin.flush()
    else:
        for m in msgs:
            p.stdin.write(frame(m)); p.stdin.flush(); time.sleep(gap)
    p.stdin.close()
    out = p.stdout.read().decode(); p.wait(timeout=60)
    return out.count('"textDocument/publishDiagnostics"'), ('"id":7' in out)
fail = 0
n, _ = session(init + [change(i) for i in range(1, 11)] + end)
print(("  ok    " if n == 2 else "  FAIL  ") + "burst: open + 10 changes at once -> %d publishes (want 2)" % n); fail |= n != 2
n, answered = session(init + [change(1), hover, change(2)] + end)
ok = n == 3 and answered
print(("  ok    " if ok else "  FAIL  ") + "between: change, hover, change -> %d publishes (want 3), hover answered: %s" % (n, answered)); fail |= not ok
n, _ = session(init + [change(i) for i in range(1, 11)] + end, gap=0.3)
print(("  ok    " if n == 11 else "  FAIL  ") + "paced: 10 changes 0.3 s apart -> %d publishes (want 11, the control)" % n); fail |= n != 11
print("lsp_coalesce: FAILED" if fail else "lsp_coalesce: ok")
sys.exit(1 if fail else 0)
PY
