#!/bin/sh
# scripts/spawn_stack_check.sh — a spawned thread gets the stack the program asked for.
#
# Q-178. Q-168 (v0.1.520) let a program say `stack = "512MB"` in mere.toml, and
# the C and LLVM backends honour it by running `main`'s work on a thread of that
# size. `spawn` did not: it called pthread_create with no attributes, so a
# spawned thread had the HOST's default -- 512 KiB on macOS, `ulimit -s` on
# Linux -- whatever the program had asked for. The same recursion that the main
# thread finishes overflowed one call to `spawn` away.
#
# And the overflow was not diagnosed there. The stack bounds the SIGSEGV handler
# compares against were process globals holding the MAIN thread's stack, and
# `sigaltstack` is per-thread and was installed on the main thread only, so a
# spawned thread that ran out of stack died with the handler unable to run:
# exit 139, nothing on stderr -- the shape v0.1.271 removed everywhere else.
#
# WHAT IS CHECKED, on both native backends:
#   1. with the request, deep recursion inside `spawn` finishes with the right answer
#   2. without it, the same program overflows AND SAYS SO ("stack overflow"), from
#      the spawned thread
#   3. the request is address space, not memory: 64 spawned threads under a
#      512MB request stay small
#
# Usage:
#   sh scripts/spawn_stack_check.sh            # check
#   sh scripts/spawn_stack_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "spawn_stack: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "spawn_stack: no C compiler — skipping"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
MODE="${1:-}"

# The recursion builds a list so no C compiler can turn it into a loop (see
# stack_request_check.sh for the -O1 accumulator that made a fixture meaningless).
N="${N:-2000000}"
WANT=$(awk "BEGIN{printf \"%.0f\", $N*($N+1)/2}")
prog() {
  cat > "$1/p.mere" <<EOF
type ilist = INil | ICons of int * ilist;
let rec build = fn n -> if n == 0 then INil else ICons (n, build (n - 1));
let rec total = fn lst -> match lst with | INil -> 0 | ICons (h, t) -> h + total t;
let out = channel_new ();
let work = fn (u: unit) -> channel_send out (total (build $N));
let h = spawn (fn () -> work ());
let _ = join h;
print_int (channel_recv out)
EOF
}
manifest() {  # $1 = dir, $2 = stack value or "" for none
  if [ -n "$2" ]; then
    printf '[package]\nname = "p"\nversion = "0.1.0"\nstack = "%s"\n' "$2" > "$1/mere.toml"
  else
    printf '[package]\nname = "p"\nversion = "0.1.0"\n' > "$1/mere.toml"
  fi
}
mkdir -p "$T/with" "$T/without"
prog "$T/with"; prog "$T/without"
manifest "$T/with" 512MB; manifest "$T/without" ""

build_run() {  # $1 = dir, $2 = flag (-c|-ll), $3 = source name -> prints first line of output
  d="$1"; flag="$2"; src="${3:-p.mere}"
  ext=c; [ "$flag" = "-ll" ] && ext=ll
  if ! "$MERE" "$flag" "$d/$src" > "$T/out.$ext" 2>"$T/emit.err"; then
    echo "EMITFAIL $(head -1 "$T/emit.err")"; return
  fi
  if ! "$CC" -O0 -o "$T/bin" "$T/out.$ext" -lm -lpthread 2>"$T/cc.err"; then
    echo "CCFAIL $(head -1 "$T/cc.err")"; return
  fi
  out=$( (cd "$d" && "$T/bin" 2>&1) ); rc=$?
  # $4 = all: every line, joined with '|' (v0.1.590: a spawned thread's failure
  # is a line on stderr when it happens, ahead of what main prints)
  if [ "${4:-}" = all ]; then printf '%s\n' "$out" | tr '\n' '|'; echo; return; fi
  first=$(printf '%s\n' "$out" | head -1)
  [ -n "$first" ] || first="(no output, exit $rc)"
  echo "$first"
}

for flag in -c -ll; do
  b=C; [ "$flag" = "-ll" ] && b=LLVM
  got_with=$(build_run "$T/with" "$flag")
  got_without=$(build_run "$T/without" "$flag")
  if [ "$got_with" = "$WANT" ]; then
    printf '  ok    %s\n' "$b: with stack = \"512MB\", $N frames inside spawn finish and the answer is right"
  else
    printf '  FAIL  %s\n' "$b: with the request, the spawned recursion gave \"$got_with\", wanted $WANT"
    fail=1
  fi
  case "$got_without" in
    *"stack overflow"*)
      printf '  ok    %s\n' "$b: without the request the spawned thread overflows and says so" ;;
    "$WANT")
      echo "spawn_stack: this host's default thread stack holds $N frames — the pair cannot measure anything; raise N" >&2
      exit 2 ;;
    *)
      printf '  FAIL  %s\n' "$b: without the request the spawned overflow was not named: $got_without"
      fail=1 ;;
  esac
done

# --- a fail on a spawned thread belongs to that thread -----------------------
# Found while writing this gate: LLVM's jmpbuf was ONE global (C has had one per
# thread since v0.1.310), so a fail on a spawned thread with no try_or of its
# own jumped into the try_or MAIN was sitting in -- onto another thread's stack
# -- and main printed the handler's value as though it had failed itself.
# v0.1.586: the thread's failure is recorded and `join` raises it (Q-090). So
# main's try_or, running while the worker fails, must come back with its own
# value (1), and the join after it must raise the worker's failure (caught: 2).
cat > "$T/without/jb.mere" <<'JB'
let go = channel_new ();
let worker = fn (u: unit) ->
  let _ = channel_recv go in
  let _ = fail "from the spawned thread" in
  ();
let h = spawn (fn () -> worker ());
let rec inner = fn (i: int) -> fn (acc: int) -> if i == 0 then acc else inner (i - 1) (acc + i % 7);
let rec outer = fn (j: int) -> fn (acc: int) -> if j == 0 then acc else outer (j - 1) (inner 1000 acc);
let r = try_or (fn (u) ->
  let _ = channel_send go 1 in
  let _ = outer 2000 0 in
  [1]) [] in
let j = try_or (fn (u) -> let _ = join h in 1) 2 in
print (str_of_int (match r with Cons (x, _) -> x | Nil -> 0 - 1) ++ " " ++ str_of_int j)
JB
for flag in -c -ll; do
  b=C; [ "$flag" = "-ll" ] && b=LLVM
  got=$(build_run "$T/without" "$flag" jb.mere all)
  case "$got" in
    *"mere: thread 1 failed: fail: from the spawned thread|"*"1 2|"*)
      printf '  ok    %s\n' "$b: a fail on a spawned thread stays in that thread's record, not main's try_or" ;;
    *) printf '  FAIL  %s\n' "$b: a spawned thread's fail landed elsewhere: $got"
       fail=1 ;;
  esac
done

# --- 64 threads under a 512MB request: address space, not memory ------------
cat > "$T/with/many.mere" <<'EOF'
let done_ch = channel_new ();
let rec start = fn (i: int) -> fn (acc: ThreadHandle list) ->
  if i == 64 then acc
  else start (i + 1) (Cons (spawn (fn () -> channel_send done_ch i), acc));
let hs = start 0 Nil;
let rec wait = fn (hs: ThreadHandle list) -> match hs with Nil -> () | Cons (h, t) -> let _ = join h in wait t;
let _ = wait hs;
print_int 64
EOF
if "$MERE" -c "$T/with/many.mere" > "$T/many.c" 2>/dev/null \
   && "$CC" -O0 -o "$T/many" "$T/many.c" -lm -lpthread 2>/dev/null; then
  rss=$( { (cd "$T/with" && /usr/bin/time -l "$T/many" >/dev/null); } 2>&1 \
         | awk '/maximum resident/ {print $1}' )
  [ -n "$rss" ] || rss=$( { (cd "$T/with" && /usr/bin/time -v "$T/many" >/dev/null); } 2>&1 \
         | awk '/Maximum resident/ {print $6 * 1024}' )
  if [ -z "$rss" ]; then
    printf '  note  %s\n' "no /usr/bin/time here — the reservation question was not asked"
  elif [ "$rss" -lt 67108864 ]; then
    printf '  ok    %s\n' "64 spawned threads under a 512MB request hold $((rss / 1024)) KiB resident"
  else
    printf '  FAIL  %s\n' "64 spawned threads under a 512MB request hold $((rss / 1024)) KiB — the stacks are being committed"
    fail=1
  fi
else
  printf '  FAIL  %s\n' "the 64-thread program did not build"
  fail=1
fi

if [ "$MODE" = "--poison" ]; then
  pfail=0
  # POISON 1: a request SMALLER than the host's default must break the spawned
  # recursion. If it still finishes, the request is not reaching `spawn` and the
  # pass above is the host's default being big enough.
  manifest "$T/with" 128K
  for flag in -c -ll; do
    b=C; [ "$flag" = "-ll" ] && b=LLVM
    got=$(build_run "$T/with" "$flag")
    case "$got" in
      *"stack overflow"*) printf '  ok    %s\n' "POISON 1 $b (128K): the spawned recursion stops, and says why" ;;
      *) printf '  FAIL  %s\n' "POISON 1 $b (128K): got \"$got\" — the size is not applied to spawn, or the overflow is unnamed"
         pfail=1 ;;
    esac
  done
  manifest "$T/with" 512MB
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "spawn_stack --poison: ok (the gate can go red)"
  else
    echo "spawn_stack --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "spawn_stack: ok"; else echo "spawn_stack: FAILED"; fi
exit "$fail"
