#!/bin/sh
# scripts/wasm_assert_strength.sh -- which Wasm substring assertions would pass
# for any program at all.
#
# WHAT THIS IS. test/test_basic.ml checks the Wasm backend in places by
# compiling a small program and asserting that some string appears in the
# emitted module. That is only a check if the string would be ABSENT from a
# program that does not have the feature. Many of them are not: the emitted
# runtime contains nearly every opcode, so an assertion naming one passes no
# matter what was compiled.
#
# HOW IT FOUND OUT IT MATTERED. Twenty of these were not merely weak, they were
# false -- they asked for i32 spellings and offset=4, the memory layout from
# before the value representation widened, and matched runtime helper functions
# the program under test does not use. They survived that layout change for a
# long time, and only surfaced when the backend stopped emitting unreachable
# prelude functions and the accidental match went away with them. Those are
# fixed. This script is about the rest.
#
# THE TEST IS A CONTROL PROGRAM. Compile the trivial program `0` once. Any
# needle that appears in THAT module cannot be evidence about a program that
# was compiled to exercise a feature. It is not wrong, it is vacuous.
#
# NOT A CI GATE, YET. It reports a known population and exits non-zero while
# any of it remains, so wiring it into CI would make CI red for a condition
# nobody is fixing this week. It is here to be run, and to let the open
# question about it retire itself when the count reaches zero.
#
#   sh scripts/wasm_assert_strength.sh          # report
#   sh scripts/wasm_assert_strength.sh --list   # and name every one
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
LIST=0
[ "${1:-}" = "--list" ] && LIST=1

[ -x "$MERE" ] || { echo "wasm_assert_strength: no compiler at $MERE (run dune build)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "wasm_assert_strength: SKIP (no python3)"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '0\n' > "$TMP/control.mere"
"$MERE" -w "$TMP/control.mere" > "$TMP/control.wat" 2>/dev/null || {
  echo "wasm_assert_strength: the control program did not compile" >&2; exit 2; }

MERE="$MERE" TMP="$TMP" LIST="$LIST" python3 - "$ROOT/test/test_basic.ml" <<'PY'
import os, re, subprocess, sys

src = open(sys.argv[1]).read()
tmp, mere, want_list = os.environ["TMP"], os.environ["MERE"], os.environ["LIST"] == "1"
control = open(os.path.join(tmp, "control.wat")).read()

pat = re.compile(
    r'assert_contains\s+"(wasm:[^"]*)"\s*\n?\s*\((?:wasm|wasm_with_decls)\s*\n?\s*'
    r'"((?:[^"\\]|\\.)*)"\)\s*\n?\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)

def unquote(s):
    s = re.sub(r'\\\n\s*', '', s)          # OCaml line continuation
    return s.replace('\\n', '\n').replace('\\"', '"')

total = vacuous = false_now = 0
rows = []
for m in pat.finditer(src):
    name, prog, needle = (unquote(g) for g in m.groups())
    total += 1
    open(os.path.join(tmp, "probe.mere"), "w").write(prog + "\n")
    r = subprocess.run([mere, "-w", os.path.join(tmp, "probe.mere")],
                       capture_output=True, text=True)
    if r.returncode != 0:
        continue
    if needle not in r.stdout:
        false_now += 1
        rows.append(("FALSE  ", name, needle))
    elif needle in control:
        vacuous += 1
        rows.append(("VACUOUS", name, needle))

if want_list:
    for kind, name, needle in rows:
        print("  %s %-52s %s" % (kind, name[:52], needle))

print("wasm_assert_strength: %d assertions, %d vacuous (also match the program 0), %d false"
      % (total, vacuous, false_now))
sys.exit(1 if (vacuous or false_now) else 0)
PY
