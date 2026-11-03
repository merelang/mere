#!/bin/sh
# OwnedVec is exclusive: foreign reads fail too. Inline spawn captures release
# direct bindings for atomic first-use claiming, as on the native backends.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
poison=0
for arg in "$@"; do
  case "$arg" in --poison) poison=1 ;;
    *) echo "wasm_ownedvec_owner: unknown option $arg" >&2; exit 2 ;;
  esac
done
for tool in node wat2wasm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "wasm_ownedvec_owner: no $tool" >&2; exit 2; }
done
[ -x "$MERE" ] || { echo "wasm_ownedvec_owner: compiler not built" >&2; exit 2; }
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
  if ! why=$(build "$1" "${3:-}"); then echo "  FAIL  wasm OwnedVec $1: $why"; fail=1; return; fi
  run_host "$ROOT/scripts/run_wasm.js"; rc=$?
  if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = "$2" ] && [ ! -s "$T/err" ]; then
    if [ -n "${3:-}" ]; then echo "  ok    POISON wasm OwnedVec $1"
    else echo "  ok    wasm OwnedVec $1"; fi
  else
    echo "  FAIL  wasm OwnedVec $1: status $rc, stdout [$(head -c 160 "$T/out")], stderr [$(head -c 160 "$T/err")]"
    fail=1
  fi
}
cat > "$T/classify" <<'EOF'
let classify = fn (op: str) -> fn (m: str) ->
  if str_starts_with m (op ++ ": an OwnedVec belongs to one thread") then "owned" else "other";
let launch = fn (f: unit -> unit) -> spawn f;
EOF
for ctor in new copy; do
  for seed in empty full; do
    case "$seed" in empty) initial='()'; size=0; first=2 ;;
      full) initial='owned_vec_push g 1'; size=1; first=1 ;;
    esac
    case "$ctor" in
      new) make='owned_vec_new ()' ;;
      copy) make='let v = vec_new () in vec_to_owned v' ;;
    esac
    while IFS='|' read -r name code expr; do
      [ "$seed:$name" = empty:get ] && continue
      case "$name" in generic_len) reason_op=owned_vec_len ;; *) reason_op="owned_vec_$name" ;; esac
      cat "$T/classify" > "$T/foreign_$ctor-$seed-$name.mere"
      cat >> "$T/foreign_$ctor-$seed-$name.mere" <<EOF
let g = $make;
let _ = $initial;
let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = $expr in "ok") (classify "$reason_op")));
let _ = join h;
let appended = try_or (fn () -> let _ = owned_vec_push g 2 in 0) 8;
let size = try_or (fn () -> owned_vec_len g) 9;
let first = try_or (fn () -> owned_vec_get g 0) 10;
print (channel_recv results ++ "|" ++ str_of_int appended ++ ":" ++ str_of_int size ++ ":" ++ str_of_int first)
EOF
      expect "foreign_$ctor-$seed-$name" "owned|0:$((size + 1)):$first"
      if [ "$poison" = 1 ]; then
        case "$code" in
          0) want="other|0:$((size + 1)):$first" ;;
          1) want='ok|8:9:1' ;;
          2) want="ok|8:$size:10" ;;
          3) want='ok|8:9:10' ;;
        esac
        expect "foreign_$ctor-$seed-$name" "$want" "/call \$mere_owned_vec_use.*(i32.const $code))).*;; ov-owner\$/d"
      fi
    done <<'OPS'
push|0|owned_vec_push g 3
get|1|owned_vec_get g 0
len|2|owned_vec_len g
generic_len|2|len g
to_vec|3|owned_vec_to_vec g
OPS
  done
  # A barrier ensures the worker claims first. Parent function aliases are
  # then refused for every access API, including reads and conversions.
  while IFS='|' read -r name expr; do
    case "$name" in generic_len) reason_op=owned_vec_len ;; *) reason_op="owned_vec_$name" ;; esac
    cat "$T/classify" > "$T/after_move_$ctor-$name.mere"
    cat >> "$T/after_move_$ctor-$name.mere" <<EOF
let g = $make;
let _ = owned_vec_push g 1;
let retained = fn () -> let _ = $expr in ();
let ready = channel_new ();
let finish = channel_new ();
let h = spawn (fn () ->
  let _ = owned_vec_len g in
  let _ = channel_send ready () in channel_recv finish);
let _ = channel_recv ready;
let result = try_or_msg (fn () -> let _ = retained () in "ok") (classify "$reason_op");
let _ = channel_send finish ();
let _ = join h;
print result
EOF
    expect "after_move_$ctor-$name" owned
  done <<'AFTER'
push|owned_vec_push g 3
get|owned_vec_get g 0
len|owned_vec_len g
generic_len|len g
to_vec|owned_vec_to_vec g
AFTER
done

cp "$ROOT/test/owner/ov_moved.mere" "$T/native_move.mere"
expect native_move 3
cat > "$T/local_move.mere" <<'EOF'
let results = channel_new ();
let h =
  let g = owned_vec_new () in let _ = owned_vec_push g 1 in
  spawn (fn () -> let _ = owned_vec_push g 2 in channel_send results (owned_vec_len g));
let _ = join h;
print_int (channel_recv results)
EOF
expect local_move 2
cat > "$T/multiple_move.mere" <<'EOF'
let a = owned_vec_new ();
let b = owned_vec_new ();
let _ = owned_vec_push a 10;
let _ = owned_vec_push b 20;
let result = channel_new ();
let h = spawn (fn () ->
  let _ = owned_vec_push a 1 in let _ = owned_vec_push b 2 in
  channel_send result (owned_vec_get a 0 + owned_vec_get b 0 + owned_vec_len a + owned_vec_len b));
let _ = join h;
print_int (channel_recv result)
EOF
expect multiple_move 34
cat > "$T/worker_ids.mere" <<'EOF'
let callbacks = channel_new ();
let ready = channel_new ();
let results = channel_new ();
let a = spawn (fn () ->
  let g = owned_vec_new () in let _ = owned_vec_push g 1 in
  let _ = channel_send callbacks (fn () -> owned_vec_len g) in
  let _ = channel_recv ready in
  let _ = owned_vec_push g 2 in channel_send results (owned_vec_len g));
let b = spawn (fn () ->
  let read = channel_recv callbacks in
  let result = try_or (fn () -> let _ = read () in 0) 7 in
  let _ = channel_send ready () in channel_send results result);
let _ = join a;
let _ = join b;
print_int (channel_recv results + channel_recv results)
EOF
expect worker_ids 9

# Copies and grows stay worker-local; the copied Vec is independent.
cat > "$T/work.mere" <<'EOF'
let rec work = fn (n: int) -> fn (total: int) ->
  if n == 32 then total else
  let padding = str_repeat "x" n in
  let v = vec_new () in let _ = vec_push v (str_len padding) in
  let g = vec_to_owned v in
  let rec fill = fn (i: int) ->
    if i == 80 then () else let _ = owned_vec_push g i in fill (i + 1) in
  let _ = fill 0 in
  let copy = owned_vec_to_vec g in let _ = vec_set copy 0 999 in
  let count = if owned_vec_get g 0 == n then owned_vec_len g + vec_len v + vec_len copy else 0 in
  work (n + 1) (total + count);
EOF
cp "$T/work.mere" "$T/local.mere"
echo 'print_int (work 0 0)' >> "$T/local.mere"
expect local 5216
if grep -Eq 'atomic\.|\$mere_owned_vec_(use|release)|__lang_thread_id' "$T/module.wat"; then
  echo "  FAIL  wasm OwnedVec local: ownership code remains without threads"; fail=1
fi
cp "$T/work.mere" "$T/threaded.mere"
cat >> "$T/threaded.mere" <<'EOF'
let results = channel_new ();
let h = spawn (fn () -> channel_send results (work 0 0));
let own = work 0 0;
let _ = join h;
print_int (own + channel_recv results)
EOF
expect threaded 10432
cat > "$T/no_owned.mere" <<'EOF'
let h = spawn (fn () -> let v = vec_new () in let _ = vec_push v 42 in print_int (vec_get v 0));
join h
EOF
expect no_owned 42
if grep -Eq '\$mere_owned_vec_(use|release)' "$T/module.wat"; then
  echo "  FAIL  wasm OwnedVec no_owned: ownership helpers remain without OwnedVec"; fail=1
fi
cat > "$T/literal.mere" <<'EOF'
let g = owned_vec_new ();
let _ = owned_vec_push g 42;
let _ = print "call $mere_owned_vec_len";
print_int (owned_vec_len g)
EOF
expect literal 'call $mere_owned_vec_len
1'

if [ "$poison" = 1 ]; then
  if why=$(build native_move '/;; ov-release$/d'); then
    run_host "$ROOT/scripts/run_wasm.js"; rc=$?
    if [ "$rc" = 1 ] && cat "$T/out" "$T/err" | grep -q 'an OwnedVec belongs to one thread'; then
      echo "  ok    POISON wasm OwnedVec missing handoff"
    else echo "  FAIL  POISON wasm OwnedVec missing handoff: status $rc"; fail=1; fi
  else echo "  FAIL  POISON wasm OwnedVec missing handoff: $why"; fail=1; fi
  expect after_move_new-len ok 's/(i32.atomic.rmw.cmpxchg offset=12 (local.get $v) (i32.const 0) (local.get $me))/(i32.atomic.load offset=12 (local.get $v))/'
  mkdir "$T/host"
  cp "$ROOT"/scripts/*.js "$T/host/"
  if why=$(build worker_ids); then
    sed 's/__lang_thread_id.value = tid + 1/__lang_thread_id.value = 2/' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    run_host "$T/host/run_wasm.js"; rc=$?
    if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = 2 ] && [ ! -s "$T/err" ]; then
      echo "  ok    POISON wasm OwnedVec duplicate identities"
    else echo "  FAIL  POISON wasm OwnedVec duplicate identities: status $rc"; fail=1; fi
  else echo "  FAIL  POISON wasm OwnedVec duplicate identities: $why"; fail=1; fi
fi
expected=36
[ "$poison" = 1 ] && expected=55
[ "$checks" = "$expected" ] || { echo "  FAIL  wasm OwnedVec: expected $expected checks, ran $checks"; fail=1; }
[ "$fail" = 0 ] || { echo "wasm_ownedvec_owner: FAILED"; exit 1; }
echo "wasm_ownedvec_owner: ok ($checks access, handoff and reuse checks, plus host controls)"
