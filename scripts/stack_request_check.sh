#!/bin/sh
# scripts/stack_request_check.sh — a program can say how much stack it needs.
#
# Q-168. Deep recursion was DIAGNOSED (v0.1.271 names it instead of exiting 139
# with an empty stderr), but nothing in the language could ASK for more. The
# answer lived outside the build and was spelled three different ways --
# `-Wl,-stack_size` on Darwin, `ulimit -s` on Linux, `--stack-size` on node --
# so whoever RAN a program had to know a fact about the PROGRAM. mere-ruby's
# tools/build.sh carries all three in comments; that is the shape of the gap.
#
# v0.1.520 reads `stack = "512MB"` from the nearest mere.toml and puts the
# program's work on a thread sized to it. ⚠ NOT a link flag: `mere -c` emits C
# and never invokes the linker, so translating the request into one could not
# reach. `main` is a thing this compiler writes, so that is where it fits.
#
# WHAT IS CHECKED, in both directions on both native backends: the same program
# OVERFLOWS without the request and COMPLETES with it, giving the right answer.
# One direction alone proves nothing -- a fixture that passes either way would
# make this gate green forever.
#
# ⚠ AND: that the request is not a reservation. A 512 MB stack that were really
# committed would be a regression dressed as a feature, so a trivial program
# built with the same request is measured for peak RSS.
#
# Usage:
#   sh scripts/stack_request_check.sh            # check
#   sh scripts/stack_request_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "stack_request: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "stack_request: no C compiler — skipping"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
# ⚠ Captured BEFORE anything runs: the refusal loop below uses `set -- $pair` to
# split a pair, which REPLACES the positional parameters -- so `$1` stopped being
# `--poison` half way down and the poison block silently never ran while the
# script still printed a pass.
MODE="${1:-}"

# Deep enough to need far more than any default (8 MB here), shallow enough to
# run in a second. The recursion builds a list so that no C compiler can flatten
# it into a loop -- at -O1 the obvious `1 + f (n-1)` became an accumulator and
# four million frames fitted in the default stack, which would have made the
# whole fixture meaningless.
N="${N:-2000000}"
prog() {
  cat > "$1/p.mere" <<EOF
type ilist = INil | ICons of int * ilist;
let rec build = fn n -> if n == 0 then INil else ICons (n, build (n - 1));
let rec total = fn lst -> match lst with | INil -> 0 | ICons (h, t) -> h + total t;
print_int (total (build $N))
EOF
}
# n*(n+1)/2 without depending on the shell's integer width
WANT=$(awk "BEGIN{printf \"%.0f\", $N*($N+1)/2}")

mkdir -p "$T/with" "$T/without"
prog "$T/with"; prog "$T/without"
printf '[package]\nname = "with"\nversion = "0.1.0"\nstack = "512MB"\n' > "$T/with/mere.toml"
printf '[package]\nname = "without"\nversion = "0.1.0"\n' > "$T/without/mere.toml"

run_one() {  # $1 = dir, $2 = flag (-c|-ll), $3 = label
  d="$1"; flag="$2"
  if ! "$MERE" "$flag" "$d/p.mere" > "$T/out.src" 2>"$T/emit.err"; then
    echo "EMITFAIL $(head -1 "$T/emit.err")"; return
  fi
  ext=c; [ "$flag" = "-ll" ] && ext=ll
  cp "$T/out.src" "$T/out.$ext"
  if ! "$CC" -O0 -o "$T/bin" "$T/out.$ext" -lm 2>"$T/cc.err"; then
    echo "CCFAIL $(head -1 "$T/cc.err")"; return
  fi
  (cd "$d" && "$T/bin" 2>&1 | head -1)
}

for flag in -c -ll; do
  b=C; [ "$flag" = "-ll" ] && b=LLVM
  got_with=$(run_one "$T/with" "$flag")
  got_without=$(run_one "$T/without" "$flag")
  case "$got_without" in
    *"stack overflow"*)
      printf '  ok    %s\n' "$b: without the request, $N frames overflow and the program says so" ;;
    "$WANT")
      # ⚠ Not a pass and not a failure of the feature: this host's default stack
      # already holds the fixture, so the pair cannot tell the two apart here.
      echo "stack_request: this host runs $N frames without a request (ulimit -s $(ulimit -s)) — the pair cannot measure anything; raise N" >&2
      exit 2 ;;
    *)
      printf '  FAIL  %s\n' "$b: without the request the program neither overflowed nor finished: $got_without"
      fail=1 ;;
  esac
  if [ "$got_with" = "$WANT" ]; then
    printf '  ok    %s\n' "$b: with stack = \"512MB\" the same program finishes, and the answer is right ($WANT)"
  else
    printf '  FAIL  %s\n' "$b: with the request the program gave \"$got_with\", wanted $WANT"
    fail=1
  fi
done

# --- the request is virtual, not a reservation ------------------------------
printf 'print_int 42\n' > "$T/with/tiny.mere"
if "$MERE" -c "$T/with/tiny.mere" > "$T/tiny.c" 2>/dev/null \
   && "$CC" -O0 -o "$T/tiny" "$T/tiny.c" -lm 2>/dev/null; then
  rss=$( { /usr/bin/time -l "$T/tiny" >/dev/null; } 2>&1 \
         | awk '/maximum resident/ {print $1}' )
  [ -n "$rss" ] || rss=$( { /usr/bin/time -v "$T/tiny" >/dev/null; } 2>&1 \
         | awk '/Maximum resident/ {print $6 * 1024}' )
  if [ -z "$rss" ]; then
    printf '  note  %s\n' "no /usr/bin/time here — the reservation question was not asked"
  elif [ "$rss" -lt 67108864 ]; then
    printf '  ok    %s\n' "a 512MB request costs $((rss / 1024)) KiB resident, so it is address space and not memory"
  else
    printf '  FAIL  %s\n' "a trivial program with a 512MB request holds $((rss / 1024)) KiB resident — the request is being committed"
    fail=1
  fi
fi

# --- the backends that cannot honour it say so ------------------------------
for pair in "-w Wasm" "-rv RV32IM"; do
  set -- $pair
  flag="$1"; name="$2"
  if "$MERE" "$flag" "$T/with/p.mere" >/dev/null 2>"$T/ref.err"; then
    printf '  FAIL  %s\n' "$name emitted a program that silently ignores the request"
    fail=1
  elif grep -q 'stack' "$T/ref.err" && grep -q "$name" "$T/ref.err"; then
    printf '  ok    %s\n' "$name refuses by name, and the message says where the stack comes from instead"
  else
    printf '  FAIL  %s\n' "$name refused, but not about the stack: $(head -1 "$T/ref.err")"
    fail=1
  fi
done

# --- a size nobody can read is refused, not ignored --------------------------
printf '[package]\nname = "bad"\nversion = "0.1.0"\nstack = "banana"\n' > "$T/with/mere.toml"
if "$MERE" -c "$T/with/tiny.mere" >/dev/null 2>"$T/bad.err"; then
  printf '  FAIL  %s\n' "an unreadable size was ignored — the program looks like it asked and did not"
  fail=1
elif grep -q 'banana' "$T/bad.err" && grep -q 'stack' "$T/bad.err"; then
  printf '  ok    %s\n' "an unreadable size is refused, and the refusal quotes what was written"
else
  printf '  FAIL  %s\n' "the build failed, but not about the size: $(head -1 "$T/bad.err" | cut -c1-60)"
  fail=1
fi
printf '[package]\nname = "with"\nversion = "0.1.0"\nstack = "512MB"\n' > "$T/with/mere.toml"

if [ "$MODE" = "--poison" ]; then
  pfail=0
  # POISON 1: a stack SMALLER than the default must break the same program, or
  # the request is not reaching the thread at all and the pass above is luck.
  printf '[package]\nname = "tiny"\nversion = "0.1.0"\nstack = "128K"\n' > "$T/with/mere.toml"
  "$MERE" -c "$T/with/p.mere" > "$T/p1.c" 2>/dev/null
  "$CC" -O0 -o "$T/p1" "$T/p1.c" -lm 2>/dev/null
  got=$( (cd "$T/with" && "$T/p1" 2>&1 | head -1) )
  if [ "$got" = "$WANT" ]; then
    printf '  FAIL  %s\n' "POISON 1: a 128K stack ran $N frames — the size is not being applied"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 1 (128K instead of 512MB): the same program stops ($got)"
  fi
  printf '[package]\nname = "with"\nversion = "0.1.0"\nstack = "512MB"\n' > "$T/with/mere.toml"
  # POISON 2: the fixture must be measuring the stack and not the answer. With
  # no manifest at all the request cannot be found, and the deep run must fail.
  rm -f "$T/with/mere.toml"
  "$MERE" -c "$T/with/p.mere" > "$T/p2.c" 2>/dev/null
  "$CC" -O0 -o "$T/p2" "$T/p2.c" -lm 2>/dev/null
  got2=$( (cd "$T/with" && "$T/p2" 2>&1 | head -1) )
  case "$got2" in
    *"stack overflow"*)
      printf '  ok    %s\n' "POISON 2 (no manifest): the request is gone and the program overflows again" ;;
    *)
      printf '  FAIL  %s\n' "POISON 2: with no manifest the program still finished ($got2)"
      pfail=1 ;;
  esac
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "stack_request --poison: ok (the gate can go red)"
  else
    echo "stack_request --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "stack_request: ok"; else echo "stack_request: FAILED"; fi
exit "$fail"
