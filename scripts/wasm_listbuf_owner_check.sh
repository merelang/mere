#!/bin/sh
# ListBuf operations mutate the builder, including lb_to_list's frozen flag.
# Run opaque callbacks on real workers and prove each guard can detect misuse.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
poison=0
for arg in "$@"; do
  case "$arg" in --poison) poison=1 ;;
    *) echo "wasm_listbuf_owner: unknown option $arg" >&2; exit 2 ;;
  esac
done
for tool in node wat2wasm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "wasm_listbuf_owner: no $tool" >&2; exit 2; }
done
[ -x "$MERE" ] || { echo "wasm_listbuf_owner: compiler not built" >&2; exit 2; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
checks=0
build() {
  "$MERE" -w "$T/$1.mere" > "$T/module.wat" 2> "$T/emit.err" || { echo "EMITFAIL $(head -1 "$T/emit.err")"; return 1; }
  if [ -n "${2:-}" ]; then
    sed "$2" "$T/module.wat" > "$T/poison.wat"
    cmp -s "$T/module.wat" "$T/poison.wat" && { echo "SEDNOMATCH"; return 1; }
    mv "$T/poison.wat" "$T/module.wat"
  fi
  wat2wasm --enable-tail-call --enable-threads "$T/module.wat" -o "$T/module.wasm" 2> "$T/emit.err" || { echo "WATFAIL $(head -1 "$T/emit.err")"; return 1; }
}
run_host() {
  sh "$ROOT/scripts/bounded.sh" 10 node "$1" "$T/module.wasm" > "$T/out" 2> "$T/err"
}
expect() {
  checks=$((checks + 1))
  if ! why=$(build "$1" "${3:-}"); then echo "  FAIL  wasm ListBuf $1: $why"; fail=1; return; fi
  run_host "$ROOT/scripts/run_wasm.js"; rc=$?
  if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = "$2" ] && [ ! -s "$T/err" ]; then
    if [ -n "${3:-}" ]; then echo "  ok    POISON wasm ListBuf $1"
    else echo "  ok    wasm ListBuf $1"; fi
  else
    echo "  FAIL  wasm ListBuf $1: status $rc, stdout [$(head -c 160 "$T/out")], stderr [$(head -c 160 "$T/err")]"
    fail=1
  fi
}
for seed in empty full; do
  case "$seed" in empty) initial='()'; expected='7:0:2:1'; sum=0; size=0 ;;
    full) initial='lb_push b 1'; expected='7:0:3:2'; sum=1; size=1 ;;
  esac
  while IFS='|' read -r op code expr; do
    cat > "$T/foreign_$seed-$op.mere" <<EOF
let launch = fn (f: unit -> unit) -> spawn f;
let mk = fn () -> let b = lb_new () in let _ = $initial in b;
let b = mk ();
let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or (fn () -> let _ = $expr in 0) 7));
let _ = join h;
let appended = try_or (fn () -> let _ = lb_push b 2 in 0) 8;
let xs = lb_to_list b;
print (str_of_int (channel_recv results) ++ ":" ++ str_of_int appended ++ ":" ++ str_of_int (list_sum xs) ++ ":" ++ str_of_int (list_len xs))
EOF
    expect "foreign_$seed-$op" "$expected"
    if [ "$poison" = 1 ]; then
      case "$op" in push) want="0:0:$((sum + 11)):$((size + 2))" ;;
        to_list) want="0:8:$sum:$size" ;;
      esac
      expect "foreign_$seed-$op" "$want" "/call \$mere_lb_write.*(i32.const $code)))/d"
    fi
  done <<'OPS'
push|0|lb_push b 9
to_list|1|lb_to_list b
OPS
done

# Conversion freezes even an empty builder. Repeated owner conversions work.
cat > "$T/frozen.mere" <<'EOF'
let results = channel_new ();
let work = fn () ->
  let b = lb_new () in
  let empty = lb_to_list b in
  let rejected = try_or (fn () -> lb_push b 1) () in
  list_len empty + list_len (lb_to_list b);
let h = spawn (fn () -> channel_send results (work ()));
let own = work ();
let _ = join h;
print_int (own + channel_recv results)
EOF
expect frozen 0

# A completed immutable list can be sent and read by multiple workers.
cat > "$T/list_messages.mere" <<'EOF'
let b = lb_new ();
let _ = lb_push b "one";
let _ = lb_push b "two";
let xs = lb_to_list b;
let results = channel_new ();
let h = spawn (fn () -> channel_send results xs);
let other = spawn (fn () -> channel_send results xs);
let _ = join h;
let _ = join other;
print_int (list_len xs + list_len (channel_recv results) + list_len (channel_recv results))
EOF
expect list_messages 6

# Both workers must have distinct identities: the builder belongs to a worker.
cat > "$T/worker_ids.mere" <<'EOF'
let callbacks = channel_new ();
let ready = channel_new ();
let results = channel_new ();
let a = spawn (fn () ->
  let b = lb_new () in let _ = lb_push b 1 in
  let _ = channel_send callbacks (fn () -> lb_push b 9) in
  let _ = channel_recv ready in
  let _ = lb_push b 2 in channel_send results (list_sum (lb_to_list b)));
let b = spawn (fn () ->
  let write = channel_recv callbacks in
  let result = try_or (fn () -> let _ = write () in 0) 7 in
  let _ = channel_send ready () in channel_send results result);
let _ = join a;
let _ = join b;
print_int (channel_recv results + channel_recv results)
EOF
expect worker_ids 10

# Uncaught ownership failures preserve the native operation-specific diagnostic.
for op in push to_list; do
  case "$op" in push) expr='lb_push b 9' ;; to_list) expr='let _ = lb_to_list b in ()' ;; esac
  cat > "$T/uncaught_$op.mere" <<EOF
let launch = fn (f: unit -> unit) -> spawn f;
let mk = fn () -> let b = lb_new () in let _ = lb_push b 1 in b;
let b = mk ();
let h = launch (fn () -> $expr);
join h
EOF
  if why=$(build "uncaught_$op"); then
    run_host "$ROOT/scripts/run_wasm.js"; rc=$?
    diagnostic="lb_$op: a ListBuf made by one thread was written by another -- a ListBuf is not safe to share between threads; give it one owner thread and send it messages over a Channel"
    if [ "$rc" = 1 ] && cat "$T/out" "$T/err" | grep -Fq "$diagnostic"; then
      echo "  ok    wasm ListBuf uncaught_$op"
    else echo "  FAIL  wasm ListBuf uncaught_$op: status $rc"; fail=1; fi
  else echo "  FAIL  wasm ListBuf uncaught_$op: $why"; fail=1; fi
done

# Padding and region reuse exercise owner initialization and atomic alignment.
cat > "$T/work.mere" <<'EOF'
let rec work = fn (n: int) -> fn (total: int) ->
  if n == 32 then total else
  let count = region R {
    let padding = str_repeat "x" n in
    let b = lb_new () in
    let _ = lb_push b (str_len padding) in let _ = lb_push b 2 in
    list_sum (lb_to_list b)
  } in work (n + 1) (total + count);
EOF
cp "$T/work.mere" "$T/local.mere"
echo 'print_int (work 0 0)' >> "$T/local.mere"
expect local 560
if grep -Eq 'atomic\.|\$mere_lb_(write|owner_init)|\$mere_container_tid|__lang_thread_id' "$T/module.wat"; then
  echo "  FAIL  wasm ListBuf local: ownership code remains without threads"; fail=1
fi
cp "$T/work.mere" "$T/threaded.mere"
cat >> "$T/threaded.mere" <<'EOF'
let results = channel_new ();
let h = spawn (fn () -> channel_send results (work 0 0));
let own = work 0 0;
let _ = join h;
print_int (own + channel_recv results)
EOF
expect threaded 1120

if [ "$poison" = 1 ]; then
  if why=$(build threaded '/local.set $b (i32.and.*;; lb-owner$/d'); then
    run_host "$ROOT/scripts/run_wasm.js"; rc=$?
    if [ "$rc" = 1 ] && cat "$T/out" "$T/err" | grep -q 'unaligned accesses'; then
      echo "  ok    POISON wasm ListBuf alignment"
    else echo "  FAIL  POISON wasm ListBuf alignment: status $rc"; fail=1; fi
  else echo "  FAIL  POISON wasm ListBuf alignment: $why"; fail=1; fi
  mkdir "$T/host"
  cp "$ROOT"/scripts/*.js "$T/host/"
  if why=$(build worker_ids); then
    sed 's/__lang_thread_id.value = tid + 1/__lang_thread_id.value = 2/' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    run_host "$T/host/run_wasm.js"; rc=$?
    if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = 12 ] && [ ! -s "$T/err" ]; then
      echo "  ok    POISON wasm ListBuf duplicate identities"
    else echo "  FAIL  POISON wasm ListBuf duplicate identities: status $rc"; fail=1; fi
  else echo "  FAIL  POISON wasm ListBuf duplicate identities: $why"; fail=1; fi
  if why=$(build uncaught_to_list); then
    for identity in 0 1073741824 -1; do
      sed "s/__lang_thread_id.value = tid + 1/__lang_thread_id.value = $identity/" "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
      run_host "$T/host/run_wasm.js"; rc=$?
      if [ "$rc" = 1 ] && cat "$T/out" "$T/err" | grep -q 'Wasm host must initialize a unique __lang_thread_id'; then
        echo "  ok    wasm ListBuf invalid worker identity $identity"
      else echo "  FAIL  wasm ListBuf invalid worker identity $identity: status $rc"; fail=1; fi
    done
  else echo "  FAIL  wasm ListBuf invalid worker identity: $why"; fail=1; fi
fi
expected=9
[ "$poison" = 1 ] && expected=13
[ "$checks" = "$expected" ] || { echo "  FAIL  wasm ListBuf: expected $expected checks, ran $checks"; fail=1; }
[ "$fail" = 0 ] || { echo "wasm_listbuf_owner: FAILED"; exit 1; }
echo "wasm_listbuf_owner: ok ($checks matrix and reuse checks, plus host controls)"
