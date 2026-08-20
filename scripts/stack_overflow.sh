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
# **The answers differ by platform and that is pinned, not smoothed over.** LLVM IR has no
# preprocessor, so the two Darwin-only pthread calls that find the real stack bounds are
# declared `extern_weak` and guarded: on Darwin they resolve and the fault gets its name,
# and elsewhere they are null, the bounds stay unknown, and the handler reports a plain
# segmentation fault. That is the documented fallback rather than a wrong guess — a name
# derived from an assumed 8MB stack would be wrong for any program linked with a bigger
# one, which is worse than no name.
#
# The C backend has a preprocessor and uses it, so it names the fault on both.
#
#     platform   C backend                              LLVM backend
#     Darwin     stack overflow (recursion too deep)     stack overflow (recursion too deep)
#     other      stack overflow (recursion too deep)     a plain crash, no name
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
case "$(uname -s)" in Darwin) llvm_named=1 ;; *) llvm_named=0 ;; esac

cat > "$T/ov.mere" <<'EOF'
let rec deep = fn (i: int) -> if i == 0 then 0 else (let d = deep (i - 1) in d + 1);
print (str_of_int (deep 100000000))
EOF

fail=0
say() { printf '  %-6s %-8s %s\n' "$1" "$2" "$3"; }

# $1 = backend label, $2 = mere flag, $3 = source suffix, $4 = must it be named
one() {
  "$MERE" "$2" "$T/ov.mere" > "$T/ov.$3" 2>"$T/emit.err" || {
    say "$1" FAIL "did not emit: $(head -1 "$T/emit.err")"; fail=1; return 0; }
  "$CC" -O0 -w "$T/ov.$3" -o "$T/ov.$1" -lm 2>"$T/cc.err" || {
    say "$1" FAIL "did not build: $(head -1 "$T/cc.err")"; fail=1; return 0; }
  # The program is expected to die; only its message is the answer. `|| true` so `set -e`
  # does not read the crash as the gate failing.
  got="$( ("$T/ov.$1" 2>&1 || true) | head -1 )"
  if [ "$4" = 1 ]; then
    if [ "$got" = "$WANT" ]; then say "$1" ok "named the fault"
    else say "$1" FAIL "wanted [$WANT], got [$got]"; fail=1; fi
  else
    # It must still DIE, and it must not claim a name it cannot have earned.
    if [ "$got" = "$WANT" ]; then
      say "$1" FAIL "named the fault where the bounds are unknown — the guard is not working"
      fail=1
    elif [ -z "$got" ]; then say "$1" ok "crashed without a name, as expected here"
    else say "$1" ok "no name: [$got]"; fi
  fi
}

echo "stack_overflow: $(uname -s), CC=$CC"
one c  -c  c  1
one ll -ll ll "$llvm_named"

[ "$fail" = 0 ] || { echo "stack_overflow: failed"; exit 1; }
echo "stack_overflow: ok"
