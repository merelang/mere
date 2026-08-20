#!/bin/sh
# scripts/stack_overflow.sh — overflow the stack on each native backend and read what it says.
#
# v0.1.271 is titled "Name the stack overflow on every backend" and the suite checks it by
# looking for `stack overflow (recursion too deep)` and `sigaltstack` IN THE EMITTED TEXT.
# That is an assertion about a string, not about a program: it stayed green while the C
# backend stopped compiling on Linux entirely and the LLVM backend stopped linking there,
# for four days, on every program. A test that reads the generated source cannot tell
# "this code says the right thing" from "this code runs".
#
# So this runs one. A program recurses until it dies, and the gate reads the message.
#
# **Both backends name it on both platforms, and getting there took three releases.** The C
# backend has a preprocessor and uses it. LLVM IR does not, and the answer went through two
# wrong shapes before the right one: the Darwin-only pthread pair emitted unconditionally
# (nothing linked off Darwin), then declared `extern_weak` and guarded (linked, but the
# handler was never installed because `stack_t` and `struct sigaction` differ too, and then
# installed but with no bounds so the fault kept no name). What it needed was `dlsym` for the
# glibc pair — `extern_weak` cannot serve, since Mach-O's linker refuses an undefined weak
# reference where ELF resolves it to zero — and seven layout constants selected at run time
# off one `icmp`.
#
# So this gate expects the same answer everywhere now. It used to carry a per-platform
# expectation, and the parity pin that recorded the same difference is gone; if a platform
# stops naming the fault, that is a regression and not a fact about the platform.
#
# Usage:  MERE=/path/to/mere.exe sh scripts/stack_overflow.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || MERE="$(command -v mere || true)"
[ -n "$MERE" ] || { echo "stack_overflow: no mere — set MERE=..." >&2; exit 1; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "stack_overflow: no C compiler" >&2; exit 0; }

T="${TMPDIR:-/tmp}/mere_stackov.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
WANT="stack overflow (recursion too deep)"

cat > "$T/ov.mere" <<'EOF'
let rec deep = fn (i: int) -> if i == 0 then 0 else (let d = deep (i - 1) in d + 1);
print (str_of_int (deep 100000000))
EOF

fail=0
say() { printf '  %-6s %-8s %s\n' "$1" "$2" "$3"; }

# $1 = backend label, $2 = mere flag, $3 = source suffix.
#
# There used to be a second mode here for a backend that was expected NOT to name the fault,
# and it is gone rather than kept: with every platform naming it, nothing reached that branch,
# and a branch nothing reaches cannot be told from a branch that is wrong. If a platform ever
# genuinely cannot answer, the branch comes back with the reason attached.
one() {
  "$MERE" "$2" "$T/ov.mere" > "$T/ov.$3" 2>"$T/emit.err" || {
    say "$1" FAIL "did not emit: $(head -1 "$T/emit.err")"; fail=1; return 0; }
  "$CC" -O0 -w "$T/ov.$3" -o "$T/ov.$1" -lm 2>"$T/cc.err" || {
    say "$1" FAIL "did not build: $(head -1 "$T/cc.err")"; fail=1; return 0; }
  # The program is expected to die; only its message is the answer. `|| true` so `set -e`
  # does not read the crash as the gate failing.
  got="$( ("$T/ov.$1" 2>&1 || true) | head -1 )"
  if [ "$got" = "$WANT" ]; then say "$1" ok "named the fault"
  else say "$1" FAIL "wanted [$WANT], got [$got]"; fail=1; fi
}

echo "stack_overflow: $(uname -s), CC=$CC"
one c  -c  c
one ll -ll ll

[ "$fail" = 0 ] || { echo "stack_overflow: failed"; exit 1; }
echo "stack_overflow: ok"
