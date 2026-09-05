#!/bin/sh
# scripts/vectorize_check.sh -- does the C the range-check versioning pass emits
# actually get vectorized by the C compiler? (Q-108)
#
# The pass exists so that a loop over a Vec has ONE exit and clang can turn it
# into SIMD. That is a property of the machine code, so this asks the machine
# code: emit test/range_version/axpy.mere to C with the pass ON and OFF, compile
# both with -O2 -S, and count vector arithmetic instructions in the functions
# REACHABLE FROM main (main itself plus every call target, transitively).
#
# Reachable, not "named like the loop": the first version of this measurement
# counted in the function whose name matched and read 0 while the copy clang
# had actually inlined and vectorized sat elsewhere. Which copy runs is decided
# by the call graph, so the call graph is what is walked.
#
# ON must contain at least one vector arithmetic instruction; OFF must contain
# none. Both are checked: a gate that only asks the positive question cannot
# tell "the pass vectorizes it" from "clang vectorizes it anyway".
#
# Architecture-specific by nature. arm64: fmul/fadd/fsub/fmla on .2d lanes
# (Apple and GNU spellings); x86-64: (v)mulpd/(v)addpd/(v)subpd/vfmadd*pd.
# Anything else is reported as a skip, loudly.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "vectorize_check: $MERE not found -- run 'dune build'" >&2; exit 1; }
# clang, not cc: the property under test is what CLANG does with the emitted C
# (the LLVM backend's output is clang's anyway, and gcc's -O2 vectorizer has a
# different cost model). Absent clang, this says so and skips.
CC="${CC:-clang}"
command -v "$CC" >/dev/null 2>&1 || { echo "vectorize_check: SKIP -- $CC not found (this gate is about clang's output)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "vectorize_check: python3 absent" >&2; exit 1; }
arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) pat='(fmul|fadd|fsub|fmla|fmls)(\.2d|\s+v[0-9]+\.2d)';;
  x86_64|amd64)  pat='\b(v?mulpd|v?addpd|v?subpd|vfmadd[0-9]*pd|vfmsub[0-9]*pd)\b';;
  *) echo "vectorize_check: SKIP -- no vector instruction pattern for $arch"; exit 0;;
esac
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
src="$ROOT/test/range_version/axpy.mere"
"$MERE" -c "$src" >"$tmp/on.c" || { echo "vectorize_check: emit (on) failed" >&2; exit 1; }
MERE_NO_RANGE_VERSION=1 "$MERE" -c "$src" >"$tmp/off.c" || { echo "vectorize_check: emit (off) failed" >&2; exit 1; }
for v in on off; do
  $CC -O2 -w -S "$tmp/$v.c" -o "$tmp/$v.s" || { echo "vectorize_check: $CC -S failed ($v)" >&2; exit 1; }
done
count() {
python3 - "$1" "$pat" <<'PY'
import re, sys
path, pat = sys.argv[1], sys.argv[2]
lines = open(path, errors="replace").read().split("\n")
# function label: `_name:` (macOS) or `name:` (ELF); local labels start with L or .L
fn_re = re.compile(r'^(_?[A-Za-z_][A-Za-z0-9_$.]*):')
call_re = re.compile(r'^\s*(?:bl|b|call|callq|jmp)\s+(_?[A-Za-z_][A-Za-z0-9_$.]*)\b')
funcs, cur = {}, None
for ln in lines:
    m = fn_re.match(ln)
    if m and not m.group(1).lstrip('_').startswith(('L', '.L')) and not m.group(1).startswith('.'):
        cur = m.group(1); funcs[cur] = []
    elif cur is not None:
        funcs[cur].append(ln)
def norm(n): return n.lstrip('_')
byname = {norm(k): v for k, v in funcs.items()}
seen, todo, total = set(), ['main'], 0
vec_re = re.compile(pat)
while todo:
    f = todo.pop()
    if f in seen or f not in byname: continue
    seen.add(f)
    body = byname[f]
    total += sum(1 for ln in body if vec_re.search(ln))
    for ln in body:
        m = call_re.match(ln)
        if m: todo.append(norm(m.group(1)))
print(total)
PY
}
on="$(count "$tmp/on.s")"; off="$(count "$tmp/off.s")"
echo "vectorize_check ($arch): vector arithmetic reachable from main -- pass on: $on, pass off: $off"
ok=1
[ "$on" -ge 1 ] || { echo "  FAIL: the pass is on and nothing reachable from main is vectorized"; ok=0; }
[ "$off" -eq 0 ] || { echo "  FAIL: with the pass off something is vectorized anyway -- the gate is not measuring the pass"; ok=0; }
[ $ok = 1 ] && echo "  ok"
[ $ok = 1 ]
