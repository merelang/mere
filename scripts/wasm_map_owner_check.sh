#!/bin/sh
# Run alongside owner_check.sh in CI; also runnable alone with [--poison].
# Exercise every storage-access API on hashed and linear Maps, including
# caught writes that must preserve the original contents.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
set -u
poison=0
for arg in "$@"; do
  case "$arg" in --poison) poison=1 ;; --wasm-only) : ;;
    *) echo "wasm_map_owner: unknown option $arg" >&2; exit 2 ;; esac
done
for tool in node wat2wasm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "wasm_map_owner: no $tool" >&2; exit 2; }
done
[ -x "$MERE" ] || { echo "wasm_map_owner: compiler not built" >&2; exit 2; }
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
  if ! why=$(build "$1"); then echo "  FAIL  wasm Map $1: $why"; fail=1; return; fi
  run_host "$ROOT/scripts/run_wasm.js"; rc=$?
  if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = "$2" ] && [ ! -s "$T/err" ]; then
    echo "  ok    wasm Map $1"
  else echo "  FAIL  wasm Map $1: status $rc, stdout [$(head -c 160 "$T/out")], stderr [$(head -c 160 "$T/err")]"; fail=1; fi
}
# Different keys cover both generated layouts and each supported key family.
# In the table, @ encodes a variant separator so | can delimit fields.
while IFS='|' read -r kind decl key1 key2; do
  decl=$(printf '%s' "$decl" | tr '@' '|')
  cat > "$T/prefix" <<EOF
$decl
let k1 = $key1;
let k2 = $key2;
let mk = fn () -> let m = map_new () in let _ = map_set m k1 10 in m;
let launch = fn (f: unit -> unit) -> spawn f;
EOF
  while IFS='|' read -r op expr; do
    cat "$T/prefix" > "$T/foreign_$kind-$op.mere"
    cat >> "$T/foreign_$kind-$op.mere" <<EOF
let m = mk ();
let results = channel_new ();
let h = launch (fn () ->
  channel_send results (try_or (fn () -> let _ = $expr in 0) 7));
let _ = join h;
print (str_of_int (channel_recv results) ++ ":" ++ str_of_int (map_get m k1) ++ ":" ++ str_of_int (map_len m))
EOF
    expect "foreign_$kind-$op" '7:10:1'
    cat "$T/prefix" > "$T/shared_$kind-$op.mere"
    cat >> "$T/shared_$kind-$op.mere" <<EOF
let m = mk ();
let h = launch (fn () -> let _ = map_get m k1 in ());
let _ = join h;
let result = try_or (fn () -> let _ = $expr in 0) 7;
print (str_of_int result ++ ":" ++ str_of_int (map_get m k1) ++ ":" ++ str_of_int (map_len m))
EOF
    expect "shared_$kind-$op" '7:10:1'
  done <<'WRITES'
update|map_set m k1 30
insert|map_set m k2 30
delete|map_delete m k1
clear|map_clear m
recycle|map_recycle m
WRITES
  while IFS='|' read -r op expr; do
    cat "$T/prefix" > "$T/read_$kind-$op.mere"
    cat >> "$T/read_$kind-$op.mere" <<EOF
let m = mk ();
let h = launch (fn () -> let _ = $expr in ());
let _ = join h;
let result = try_or (fn () -> let _ = map_set m k1 30 in 0) 7;
print (str_of_int result ++ ":" ++ str_of_int (map_get m k1) ++ ":" ++ str_of_int (map_len m))
EOF
    expect "read_$kind-$op" '7:10:1'
  done <<'READS'
get|map_get m k1
has|map_has m k1
has_other|map_has m k2
len|map_len m
iter|map_iter m (fn k -> fn v -> ())
READS
  while IFS='|' read -r op expr; do
    cat "$T/prefix" > "$T/empty_$kind-$op.mere"
    cat >> "$T/empty_$kind-$op.mere" <<EOF
let m = map_new ();
let h = launch (fn () -> let _ = $expr in ());
let _ = join h;
let result = try_or (fn () -> let _ = map_set m k1 30 in 0) 7;
print (str_of_int result ++ ":" ++ str_of_int (map_len m))
EOF
    expect "empty_$kind-$op" '7:0'
  done <<'EMPTY_READS'
has|map_has m k1
len|map_len m
iter|map_iter m (fn k -> fn v -> ())
EMPTY_READS
  cat "$T/prefix" > "$T/readonly_$kind.mere"
  cat >> "$T/readonly_$kind.mere" <<'EOF'
let m = mk ();
let results = channel_new ();
let a = launch (fn () -> channel_send results (map_get m k1));
let b = launch (fn () -> channel_send results (map_get m k1));
let _ = join a;
let _ = join b;
print_int (channel_recv results + channel_recv results + map_get m k1)
EOF
  expect "readonly_$kind" 30
  cat "$T/prefix" > "$T/local_$kind.mere"
  cat >> "$T/local_$kind.mere" <<'EOF'
let work = fn () ->
  let m = map_new () in
  let _ = map_set m k1 10 in let _ = map_set m k1 20 in
  let values = vec_new () in
  let _ = map_iter m (fn k -> fn v -> vec_push values v) in
  let observed = vec_get values 0 in
  let _ = map_delete m k1 in let deleted = map_len m == 0 in
  let _ = map_set m k1 21 in let _ = map_clear m in let cleared = not (map_has m k1) in
  let _ = map_set m k1 22 in let _ = map_recycle m in let recycled = map_len m == 0 in
  let _ = map_set m k1 42 in
  if observed == 20 && deleted && cleared && recycled then map_get m k1 else 0;
EOF
  sed '/^let launch =/d' "$T/local_$kind.mere" > "$T/unthreaded_$kind.mere"
  echo 'print_int (work ())' >> "$T/unthreaded_$kind.mere"
  expect "unthreaded_$kind" 42
  if grep -Eq 'atomic\.|\$mere_map_(read|write|owner_init)|\$mere_container_tid|__lang_thread_id' "$T/module.wat"; then
    echo "  FAIL  wasm Map unthreaded_$kind: ownership code remains"; fail=1
  fi
  cat >> "$T/local_$kind.mere" <<'EOF'
let results = channel_new ();
let h = spawn (fn () -> channel_send results (work ()));
let own_total = work ();
let _ = join h;
print_int (own_total + channel_recv results)
EOF
  expect "local_$kind" 84
done <<'KEYS'
int||1|2
str||"one"|"two"
bool||false|true
tuple||(1, "one")|(2, "two")
record|type key = { kx: int, kname: str };|key { kx = 1, kname = "one" }|key { kx = 2, kname = "two" }
variant|type key = First of int @ Second of str;|First 1|Second "two"
KEYS
cp "$ROOT/test/owner/map_alignment.mere" "$T/alignment.mere"
expect alignment 736
cp "$ROOT/test/owner/map_growth.mere" "$T/growth.mere"
expect growth 224
cp "$ROOT/test/owner/map_worker_ids.mere" "$T/worker_ids.mere"
if why=$(build worker_ids); then
  run_host "$ROOT/scripts/run_wasm.js"; rc=$?
  if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = 7 ] && grep -q 'another thread has read was written' "$T/err"; then
    echo "  ok    wasm Map distinct worker identities"
  else echo "  FAIL  wasm Map distinct worker identities"; fail=1; fi
else echo "  FAIL  wasm Map worker identities: $why"; fail=1; fi

if [ "$poison" = 1 ]; then
  for kind in int tuple; do
    if why=$(build "foreign_$kind-update" '/call $mere_map_write.*;; map-owner$/d'); then
      run_host "$ROOT/scripts/run_wasm.js"; rc=$?
      if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = '0:30:1' ] && [ ! -s "$T/err" ]; then
        echo "  ok    POISON wasm Map $kind write guard: mutation succeeds"
      else echo "  FAIL  POISON wasm Map $kind write guard"; fail=1; fi
    else echo "  FAIL  POISON wasm Map $kind write guard: $why"; fail=1; fi
    if why=$(build "read_$kind-get" '/call $mere_map_read.*;; map-owner$/d'); then
      run_host "$ROOT/scripts/run_wasm.js"; rc=$?
      if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = '0:30:1' ] && [ ! -s "$T/err" ]; then
        echo "  ok    POISON wasm Map $kind read mark: owner writes again"
      else echo "  FAIL  POISON wasm Map $kind read mark"; fail=1; fi
    else echo "  FAIL  POISON wasm Map $kind read mark: $why"; fail=1; fi
  done
  mkdir "$T/host"
  cp "$ROOT"/scripts/*.js "$T/host/"
  if why=$(build worker_ids); then
    sed 's/__lang_thread_id.value = tid + 1/__lang_thread_id.value = 2/' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    run_host "$T/host/run_wasm.js"; rc=$?
    if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = 0 ] && [ ! -s "$T/err" ]; then
      echo "  ok    POISON wasm Map duplicate identities: shared write succeeds"
    else echo "  FAIL  POISON wasm Map duplicate identities"; fail=1; fi
  else echo "  FAIL  POISON wasm Map duplicate identities: $why"; fail=1; fi
  cp "$ROOT/test/owner/param_map.mere" "$T/config.mere"
  if why=$(build config); then
    sed '/__lang_thread_id.value = tid + 1/d' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    run_host "$T/host/run_wasm.js"; rc=$?
    if [ "$rc" = 1 ] && cat "$T/out" "$T/err" | grep -q 'Wasm host must initialize a unique __lang_thread_id'; then
      echo "  ok    wasm Map without worker identity: refused by name"
    else echo "  FAIL  wasm Map without worker identity"; fail=1; fi
  else echo "  FAIL  wasm Map worker identity: $why"; fail=1; fi
  if why=$(build alignment '/local.set $m (i32.and.*;; map-owner$/d'); then
    run_host "$ROOT/scripts/run_wasm.js"; rc=$?
    if [ "$rc" = 1 ] && cat "$T/out" "$T/err" | grep -q 'unaligned accesses'; then
      echo "  ok    POISON wasm Map alignment: unaligned atomic access traps"
    else echo "  FAIL  POISON wasm Map alignment"; fail=1; fi
  else echo "  FAIL  POISON wasm Map alignment: $why"; fail=1; fi
fi
[ "$checks" = 128 ] || { echo "  FAIL  wasm Map: expected 128 matrix/alignment/growth checks, ran $checks"; fail=1; }
[ "$fail" = 0 ] || { echo "wasm_map_owner: FAILED"; exit 1; }
echo "wasm_map_owner: ok ($checks matrix/alignment/growth checks, plus worker identity checks)"
