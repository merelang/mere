#!/bin/sh
# Unsupported worker-side thread operations must reach the parent as failures.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
poison=0
for arg in "$@"; do
  case "$arg" in --poison) poison=1 ;;
    *) echo "wasm_worker_thread: unknown option $arg" >&2; exit 2 ;;
  esac
done
for tool in node wat2wasm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "wasm_worker_thread: no $tool" >&2; exit 2; }
done
[ -x "$MERE" ] || { echo "wasm_worker_thread: compiler not built" >&2; exit 2; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
checks=0
build() {
  "$MERE" -w "$T/$1.mere" > "$T/module.wat" 2> "$T/err" &&
    wat2wasm --enable-tail-call --enable-threads "$T/module.wat" -o "$T/module.wasm" 2>> "$T/err"
}
run() {
  sh "$ROOT/scripts/bounded.sh" 10 node "$1" "$T/module.wasm" > "$T/out" 2> "$T/err"
}
for op in spawn join detach; do
  case "$op" in
    spawn) child=''; body='let _ = spawn (fn () -> print "nested-ran") in ()'; tid=1 ;;
    join|detach) child='let child = spawn (fn () -> ());'; body="$op child"; tid=2 ;;
  esac
  cat > "$T/common" <<EOF
let launch = fn (f: unit -> unit) -> spawn f;
$child
let results = channel_new ();
let worker = launch (fn () ->
  let _ = try_or (fn () -> $body) () in
  channel_send results 42);
EOF
  for mode in caught uncaught channel; do
    name="$op-$mode"
    cp "$T/common" "$T/$name.mere"
    case "$mode" in
      caught) echo 'print (try_or_msg (fn () -> let _ = join worker in "ok:" ++ str_of_int (channel_recv results)) (fn (m: str) -> "caught:" ++ m))' >> "$T/$name.mere" ;;
      uncaught) echo 'join worker' >> "$T/$name.mere" ;;
      channel) cat >> "$T/$name.mere" <<'EOF'
let _ = channel_sender results worker;
let _ = print (try_or_msg (fn () -> str_of_int (channel_recv results)) (fn (m: str) -> "caught:" ++ m));
try_or (fn () -> join worker) ()
EOF
        ;;
    esac
    checks=$((checks + 1))
    if ! build "$name"; then echo "  FAIL  $name: build $(head -1 "$T/err")"; fail=1; continue; fi
    run "$ROOT/scripts/run_wasm.js"; rc=$?
    reason="trap: $op: not supported inside a Wasm worker"
    good=0
    if [ "$mode" = uncaught ]; then
      [ "$rc" = 1 ] && [ "$(cat "$T/out")" = "$reason" ] && good=1
    elif [ "$mode" = channel ]; then
      [ "$rc" = 0 ] && [ "$(cat "$T/out")" = "caught:channel_recv: sender thread $tid failed: $reason" ] && good=1
    else
      [ "$rc" = 0 ] && [ "$(cat "$T/out")" = "caught:$reason" ] && good=1
    fi
    if [ "$good" = 1 ] && grep -qF "mere: thread $tid failed: $reason" "$T/err"; then
      echo "  ok    $name"
    else
      echo "  FAIL  $name: status $rc, stdout [$(head -c 160 "$T/out")], stderr [$(head -c 200 "$T/err")]"
      fail=1
    fi
  done
  if [ "$poison" = 1 ]; then
    checks=$((checks + 1))
    mkdir -p "$T/host"
    cp "$ROOT"/scripts/*.js "$T/host/"
    sed "s/mere_$op: () => unsupportedThreadOp(\"$op\"), \/\/ worker-thread-guard/mere_$op: stub, \/\/ worker-thread-guard/" "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    if cmp -s "$ROOT/scripts/run_wasm.js" "$T/host/run_wasm.js" || ! build "$op-caught"; then
      echo "  FAIL  POISON $op: guard not found or fixture did not build"; fail=1; continue
    fi
    run "$T/host/run_wasm.js"; rc=$?
    if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = 'ok:42' ] && [ ! -s "$T/err" ]; then
      echo "  ok    POISON $op: former stub hides the unsupported operation"
    else echo "  FAIL  POISON $op: status $rc, stdout [$(head -c 160 "$T/out")], stderr [$(head -c 200 "$T/err")]"; fail=1; fi
  fi
done
cat > "$T/main.mere" <<'EOF'
let results = channel_new ();
let a = spawn (fn () -> channel_send results 20);
let _ = join a;
let b = spawn (fn () -> channel_send results 22);
let _ = detach b;
print_int (channel_recv results + channel_recv results)
EOF
checks=$((checks + 1))
if build main; then
  run "$ROOT/scripts/run_wasm.js"; rc=$?
  if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = 42 ] && [ ! -s "$T/err" ]; then echo "  ok    main-instance spawn, join and detach"
  else echo "  FAIL  main-instance operations: status $rc"; fail=1; fi
else echo "  FAIL  main-instance fixture did not build"; fail=1; fi
expected=10
[ "$poison" = 1 ] && expected=13
[ "$checks" = "$expected" ] || { echo "  FAIL  expected $expected checks, ran $checks"; fail=1; }
[ "$fail" = 0 ] || { echo "wasm_worker_thread: FAILED"; exit 1; }
echo "wasm_worker_thread: ok ($checks failure-propagation and main-instance checks)"
