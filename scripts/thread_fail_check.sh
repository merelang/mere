#!/bin/sh
# scripts/thread_fail_check.sh — what a spawned thread's failure does to the
# program, asked of every backend, many times (Q-090, v0.1.586).
#
# Until v0.1.586 the four backends gave three answers. C and LLVM ended the
# process from the failing thread, racing the main thread's last write: the exit
# status was 1 in some runs and 0 in others and stdout was sometimes cut. Wasm
# printed the failure and exited 0. The interpreter said nothing. A daemon whose
# detached handler failed once was gone (mhttpd, mengd).
#
# Now all four give Rust's answer, and this gate holds them to it. The failure
# is ONE line on stderr when the thread fails, whoever holds its handle (v0.1.590;
# v0.1.586 printed an unclaimed one at exit, which a daemon never reaches):
#     mere: thread 1 failed: fail: boom
#
#   spawned_fail   nobody joins the thread that failed: exit 0, the program's
#                  own output, and the line
#   joined_fail    `join` raises the failure again in the joiner: exit 1, the
#                  failure's message, and nothing after the join runs
#   join_caught    ... and try_or takes it like any other: prints 7 (and the line)
#   detached_fail  a detached thread's failure: the line, and the program
#                  carries on
#   par_map_fail   par_map joins each element's thread before its result
#                  (v0.1.590): a failing element is raised in the caller --
#                  "3" from the par_map that passes, then exit 1 with fail: boom --
#                  where it used to wait for good
#   MERE_THREAD_REPORT=1  the leak report names the dead thread and its message
#
# spawned_fail runs $RUNS times per backend: the old answer was a coin flip, and
# a coin flip passes a gate that asks once.
#
# --poison takes each piece out of the emitted C, LLVM IR or Wasm and the program
# that depends on it must then fail its check (the interpreter's is not text).
#
# Usage: sh scripts/thread_fail_check.sh [--poison]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}
FX="$ROOT/test/threadfail"
RUNS=${RUNS:-10}
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
[ -x "$MERE" ] || { echo "thread_fail_check: $MERE not found — run dune build first" >&2; exit 1; }

BES="interp c ll"
HAVE_WASM=0
if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then BES="$BES w"; HAVE_WASM=1; fi

# v0.1.590: one line, when the thread fails, whoever holds its handle
LINE="mere: thread 1 failed: fail: boom"

# build <prog> <be> [sed expr] -> prints the command to run, or fails with why
build() {
  src="$FX/$1.mere"
  case "$2" in
    interp) echo "$MERE $src"; return 0 ;;
    c)  "$MERE" -c "$src" > "$TMP/g.c" 2>"$TMP/e" || { echo "EMITFAIL $(head -1 "$TMP/e")"; return 1; }
        g="$TMP/g.c" ;;
    ll) "$MERE" -ll "$src" > "$TMP/g.ll" 2>"$TMP/e" || { echo "EMITFAIL $(head -1 "$TMP/e")"; return 1; }
        g="$TMP/g.ll" ;;
    w)  "$MERE" -w "$src" > "$TMP/g.wat" 2>"$TMP/e" || { echo "EMITFAIL $(head -1 "$TMP/e")"; return 1; }
        g="$TMP/g.wat" ;;
  esac
  if [ -n "${3:-}" ]; then
    sed "$3" "$g" > "$g.p"
    cmp -s "$g" "$g.p" && { echo "SEDNOMATCH"; return 1; }
    mv "$g.p" "$g"
  fi
  case "$2" in
    c)  "$CC" -w -O1 "$g" -o "$TMP/bin_$1_c" -lm -lpthread 2>"$TMP/e" || { echo "CCFAIL $(head -1 "$TMP/e")"; return 1; }
        echo "$TMP/bin_$1_c" ;;
    ll) "$CC" -w -O1 -x ir "$g" -o "$TMP/bin_$1_ll" -lm -lpthread 2>"$TMP/e" || { echo "CCFAIL $(grep -m1 error "$TMP/e")"; return 1; }
        echo "$TMP/bin_$1_ll" ;;
    w)  wat2wasm --enable-tail-call --enable-threads "$g" -o "$TMP/bin_$1.wasm" 2>"$TMP/e" || { echo "WATFAIL $(head -1 "$TMP/e")"; return 1; }
        echo "node $ROOT/scripts/run_wasm.js $TMP/bin_$1.wasm" ;;
  esac
}

run() { sh "$ROOT/scripts/bounded.sh" 30 $1 > "$TMP/o" 2> "$TMP/e"; echo $?; }

# judge <prog> <be> <rc> -> "ok" or why not (reads $TMP/o and $TMP/e)
judge() {
  out=$(cat "$TMP/o"); err=$(cat "$TMP/e")
  # Wasm writes an uncaught failure to stdout, as it does every one of its own
  all="$out$err"
  case "$1" in
    spawned_fail)
      [ "$3" = 0 ] || { echo "exit $3, want 0"; return; }
      [ "$out" = 0 ] || { echo "stdout [$out], want [0]"; return; }
      [ "$err" = "$LINE" ] || { echo "stderr [$err], want [$LINE]"; return; } ;;
    joined_fail)
      [ "$3" = 1 ] || { echo "exit $3, want 1"; return; }
      case "$all" in *"fail: boom"*) ;; *) echo "no 'fail: boom' in the output"; return ;; esac
      case "$err" in *"$LINE"*) ;; *) echo "no [$LINE] when the thread failed"; return ;; esac
      case "$out" in *after*) echo "ran past the join"; return ;; esac ;;
    join_caught)
      [ "$3" = 0 ] || { echo "exit $3, want 0"; return; }
      [ "$out" = 7 ] || { echo "stdout [$out], want [7]"; return; }
      [ "$err" = "$LINE" ] || { echo "stderr [$err], want [$LINE]"; return; } ;;
    par_map_fail)
      [ "$3" = 1 ] || { echo "exit $3, want 1 (or it hung: 124/142 from the bound)"; return; }
      [ "$(echo "$out" | head -1)" = "3" ] || { echo "stdout [$out], want [3] first"; return; }
      case "$all" in *"fail: boom"*) ;; *) echo "no 'fail: boom' in the output"; return ;; esac ;;
    detached_fail)
      [ "$3" = 0 ] || { echo "exit $3, want 0"; return; }
      [ "$out" = after ] || { echo "stdout [$out], want [after]"; return; }
      [ "$err" = "$LINE" ] || { echo "stderr [$err], want [$LINE]"; return; } ;;
  esac
  echo ok
}

fail=0
for be in $BES; do
  for prog in spawned_fail joined_fail join_caught detached_fail par_map_fail; do
    if ! cmd=$(build "$prog" "$be"); then echo "  FAIL  $be $prog: $cmd"; fail=1; continue; fi
    n=1; [ "$prog" = spawned_fail ] && n=$RUNS
    bad=""; i=0
    while [ "$i" -lt "$n" ]; do
      rc=$(run "$cmd"); v=$(judge "$prog" "$be" "$rc")
      [ "$v" = ok ] || { bad="$v"; break; }
      i=$((i + 1))
    done
    if [ -z "$bad" ]; then echo "  ok    $be $prog ($n run(s))"
    else echo "  FAIL  $be $prog (run $((i + 1)) of $n): $bad"; fail=1; fi
  done
  # the leak report, asked for
  if cmd=$(build spawned_fail "$be"); then
    MERE_THREAD_REPORT=1 sh "$ROOT/scripts/bounded.sh" 30 $cmd > "$TMP/o" 2> "$TMP/e"
    if grep -q "thread 1: died: fail: boom, never joined" "$TMP/e"; then echo "  ok    $be MERE_THREAD_REPORT names the dead thread"
    else echo "  FAIL  $be MERE_THREAD_REPORT=1 did not name the dead thread: [$(tr '\n' ' ' < "$TMP/e")]"; fail=1; fi
  fi
done
[ "$HAVE_WASM" = 1 ] || echo "  note  wat2wasm/node missing: Wasm not checked"

if [ "${1:-}" = --poison ]; then
  pf=0
  while IFS='|' read -r prog be what expr; do
    [ -n "$be" ] || continue
    case "$be" in w) [ "$HAVE_WASM" = 1 ] || continue ;; esac
    if ! cmd=$(build "$prog" "$be" "$expr"); then echo "  FAIL  POISON $be ($what): $cmd"; pf=1; continue; fi
    caught=""; i=0
    while [ "$i" -lt "$RUNS" ]; do
      rc=$(run "$cmd"); v=$(judge "$prog" "$be" "$rc")
      [ "$v" = ok ] || { caught="$v"; break; }
      i=$((i + 1))
    done
    if [ -n "$caught" ]; then echo "  ok    POISON $be ($what): $prog fails: $caught"
    else echo "  FAIL  POISON $be ($what): $prog still passes -- the gate does not witness it"; pf=1; fi
  done <<'POISONS'
spawned_fail|c|the thread does not catch its own failure|s/^  __lang_fail_jmpbuf_set = 1;$//
joined_fail|c|join does not raise it again|s/^  if (failed) __lang_fail_impl(m);$//
detached_fail|c|a failure is not told when it happens|/^    __lang_thr_tell(__t, "");/d
joined_fail|ll|join does not raise it again|s/^  br i1 %failed, label %raise, label %ok$/  br label %ok/
spawned_fail|ll|a failure is not told when it happens|/^  call void @__lang_thr_tell(ptr %thr, ptr @.thr_none)$/d
spawned_fail|w|the worker prints and traps as before|/(if (global.get $__lang_in_thread)/,+1d
par_map_fail|c|par_map does not join|s/({ __lang_thr_join(\([^;]*\)); 0; })/0/g
joined_fail|w|join does not raise it again|s/(then (call $__lang_fail (i64.extend_i32_u (local.get $r))))/(then (i64.const 0))/
POISONS
  [ "$pf" = 0 ] || { echo "thread_fail_check --poison: FAILED"; exit 1; }
fi
[ "$fail" = 0 ] || { echo "thread_fail_check: FAILED"; exit 1; }
if [ "${1:-}" = --poison ]; then echo "thread_fail_check --poison: ok (the gate can go red)"
else echo "thread_fail_check: ok (four backends, one answer)"; fi
