#!/bin/sh
# Exercise StrBuf/ByteBuf ownership through opaque callbacks on real workers.
# --poison removes each access guard to show that the witnesses detect it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
poison=0
for arg in "$@"; do
  case "$arg" in --poison) poison=1 ;;
    *) echo "wasm_buffer_owner: unknown option $arg" >&2; exit 2 ;;
  esac
done
for tool in node wat2wasm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "wasm_buffer_owner: no $tool" >&2; exit 2; }
done
[ -x "$MERE" ] || { echo "wasm_buffer_owner: compiler not built" >&2; exit 2; }
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
  if ! why=$(build "$1" "${3:-}"); then echo "  FAIL  wasm buffer $1: $why"; fail=1; return; fi
  run_host "$ROOT/scripts/run_wasm.js"; rc=$?
  if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = "$2" ] && [ ! -s "$T/err" ]; then
    if [ -n "${3:-}" ]; then echo "  ok    POISON wasm buffer $1"
    else echo "  ok    wasm buffer $1"; fi
  else
    echo "  FAIL  wasm buffer $1: status $rc, stdout [$(head -c 160 "$T/out")], stderr [$(head -c 160 "$T/err")]"
    fail=1
  fi
}
for kind in strbuf bytebuf; do
  case "$kind" in
    strbuf)
      label=StrBuf
      make='strbuf_new ()'; seed='strbuf_push b "a"'
      observe='strbuf_to_str b ++ ":" ++ str_of_int (strbuf_len b)'
      initial='a:1'; mutated='ab:2'
      writes='push|strbuf_push b "b"'
      reads='len|strbuf_len b
len_generic|len b
snapshot|strbuf_to_str b'
      ;;
    bytebuf)
      label=ByteBuf
      make='bytebuf_of_bytes (bytes_of_hex "0a")'; seed='()'
      observe='str_of_int (bytebuf_get b 0) ++ ":" ++ str_of_int (bytebuf_len b)'
      initial='10:1'; mutated='10:2'
      writes='set|bytebuf_set b 0 30
push|bytebuf_push b 20'
      reads='len|bytebuf_len b
get|bytebuf_get b 0
snapshot|bytes_of_bytebuf b'
      ;;
  esac
  cat > "$T/prefix" <<EOF
let mk = fn () -> let b = $make in let _ = $seed in b;
let launch = fn (f: unit -> unit) -> spawn f;
EOF
  while IFS='|' read -r op write; do
    cat "$T/prefix" > "$T/foreign_$kind-$op.mere"
    cat >> "$T/foreign_$kind-$op.mere" <<EOF
let b = mk ();
let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or (fn () -> let _ = $write in 0) 7));
let _ = join h;
print (str_of_int (channel_recv results) ++ ":" ++ ($observe))
EOF
    expect "foreign_$kind-$op" "7:$initial"
    if [ "$poison" = 1 ]; then
      case "$op" in set) want='0:30:1' ;; *) want="0:$mutated" ;; esac
      expect "foreign_$kind-$op" "$want" "/call \$mere_${kind}_write.*;; buffer-owner\$/d"
    fi
    while IFS='|' read -r readop read; do
      cat "$T/prefix" > "$T/shared_$kind-$op-$readop.mere"
      cat >> "$T/shared_$kind-$op-$readop.mere" <<EOF
let b = mk ();
let h = launch (fn () -> let _ = $read in ());
let _ = join h;
let result = try_or (fn () -> let _ = $write in 0) 7;
print (str_of_int result ++ ":" ++ ($observe))
EOF
      expect "shared_$kind-$op-$readop" "7:$initial"
      if [ "$poison" = 1 ]; then
        expect "shared_$kind-$op-$readop" "$want" "/call \$mere_${kind}_read.*;; buffer-owner\$/d"
      fi
    done <<EOF
$reads
EOF
  done <<EOF
$writes
EOF
  # Reads of empty containers freeze them too, including zero-byte snapshots.
  case "$kind" in
    strbuf) empty='strbuf_new ()'; push='strbuf_push b "x"' ;;
    bytebuf) empty='bytebuf_new 0'; push='bytebuf_push b 1' ;;
  esac
  while IFS='|' read -r readop read; do
    [ "$readop" = get ] && continue
    cat > "$T/empty_$kind-$readop.mere" <<EOF
let launch = fn (f: unit -> unit) -> spawn f;
let b = $empty;
let h = launch (fn () -> let _ = $read in ());
let _ = join h;
print_int (try_or (fn () -> let _ = $push in 0) 7)
EOF
    expect "empty_$kind-$readop" 7
  done <<EOF
$reads
EOF
  # Snapshot outputs are values: they may cross threads without freezing b.
  case "$kind" in
    strbuf) snapshot='strbuf_to_str b'; measure='str_len saved' ;;
    bytebuf) snapshot='bytes_of_bytebuf b'; measure='bytes_len saved' ;;
  esac
  cat "$T/prefix" > "$T/snapshot_$kind.mere"
  cat >> "$T/snapshot_$kind.mere" <<EOF
let b = mk ();
let saved = $snapshot;
let results = channel_new ();
let h = spawn (fn () -> channel_send results ($measure));
let _ = $push;
let _ = join h;
print_int (channel_recv results * 10 + ${kind}_len b)
EOF
  expect "snapshot_$kind" 12
  # A worker-owned buffer crosses an opaque callback into a second worker.
  # Channel barriers order the read before the owner's attempted write.
  cat > "$T/worker_ids_$kind.mere" <<EOF
let callbacks = channel_new ();
let ready = channel_new ();
let results = channel_new ();
let a = spawn (fn () ->
  let b = $make in let _ = $seed in
  let _ = channel_send callbacks (fn () -> ${kind}_len b) in
  let _ = channel_recv ready in
  channel_send results (try_or (fn () -> let _ = $push in 0) 7));
let b = spawn (fn () ->
  let read = channel_recv callbacks in
  let _ = read () in channel_send ready ());
let _ = join b;
let _ = join a;
print_int (channel_recv results)
EOF
  expect "worker_ids_$kind" 7
  # An uncaught worker failure must still reach join with its diagnostic.
  cat "$T/prefix" > "$T/uncaught_$kind.mere"
  cat >> "$T/uncaught_$kind.mere" <<EOF
let b = mk ();
let h = launch (fn () -> $push);
join h
EOF
  if why=$(build "uncaught_$kind"); then
    run_host "$ROOT/scripts/run_wasm.js"; rc=$?
    diagnostic="${kind}_push: a $label made by one thread was written by another -- a $label is not safe to share between threads; give it one owner thread and send it messages over a Channel"
    if [ "$rc" = 1 ] && cat "$T/out" "$T/err" | grep -Fq "$diagnostic"; then
      echo "  ok    wasm buffer uncaught_$kind"
    else echo "  FAIL  wasm buffer uncaught_$kind: status $rc"; fail=1; fi
  else echo "  FAIL  wasm buffer uncaught_$kind: $why"; fail=1; fi
done

# Allocate after odd-sized strings and buffers, grow through many capacities,
# and reuse scratch regions on both instances. Conversions retain their bytes.
cat > "$T/local.mere" <<'EOF'
let rec work = fn (n: int) -> fn (total: int) ->
  if n == 24 then total else
  let result = region R {
    let padding = str_repeat "p" n in
    let s = strbuf_new () in
    let b = bytebuf_new (str_len padding) in
    let _ = strbuf_push s padding in
    let rec fill = fn (i: int) ->
      if i == 80 then () else
      let _ = strbuf_push s "x" in let _ = bytebuf_push b i in fill (i + 1) in
    let _ = fill 0 in
    let _ = bytebuf_set b 0 255 in
    let saved = bytes_of_bytebuf b in
    let copy = bytebuf_of_bytes saved in
    let _ = bytebuf_set copy 0 7 in
    if bytes_get saved 0 == 255 && bytebuf_get copy 0 == 7 && strbuf_len s == str_len (strbuf_to_str s)
    then bytebuf_len b + strbuf_len s else 0
  } in work (n + 1) (total + result);
print_int (work 0 0)
EOF
expect local 4392
if grep -Eq 'atomic\.|\$mere_(strbuf|bytebuf)_(read|write|owner_init)|\$mere_container_tid|__lang_thread_id' "$T/module.wat"; then
  echo "  FAIL  wasm buffer local: ownership code remains without threads"; fail=1
fi
sed '$d' "$T/local.mere" > "$T/threaded.mere"
cat >> "$T/threaded.mere" <<'EOF'
let results = channel_new ();
let h = spawn (fn () -> channel_send results (work 0 0));
let own_total = work 0 0;
let _ = join h;
print_int (own_total + channel_recv results)
EOF
expect threaded 8784
if [ "$poison" = 1 ]; then
  # StrBuf previously had no alignment; ByteBuf already aligns to four bytes.
  checks=$((checks + 1))
  if why=$(build threaded '/local.set $sb (i32.and.*;; buffer-owner$/d'); then
    run_host "$ROOT/scripts/run_wasm.js"; rc=$?
    if [ "$rc" = 1 ] && cat "$T/out" "$T/err" | grep -q 'unaligned accesses'; then
      echo "  ok    POISON wasm buffer StrBuf alignment"
    else echo "  FAIL  POISON wasm buffer StrBuf alignment: status $rc"; fail=1; fi
  else echo "  FAIL  POISON wasm buffer StrBuf alignment: $why"; fail=1; fi
  mkdir "$T/host"
  cp "$ROOT"/scripts/*.js "$T/host/"
  for kind in strbuf bytebuf; do
    if why=$(build "worker_ids_$kind"); then
      sed 's/__lang_thread_id.value = tid + 1/__lang_thread_id.value = 2/' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
      run_host "$T/host/run_wasm.js"; rc=$?
      if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = 0 ] && [ ! -s "$T/err" ]; then
        echo "  ok    POISON wasm buffer $kind duplicate identities"
      else echo "  FAIL  POISON wasm buffer $kind duplicate identities: status $rc"; fail=1; fi
      if ! why=$(build "uncaught_$kind"); then
        echo "  FAIL  wasm buffer $kind invalid identity probe: $why"; fail=1; continue
      fi
      for identity in 0 1073741824 -1; do
        sed "s/__lang_thread_id.value = tid + 1/__lang_thread_id.value = $identity/" "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
        run_host "$T/host/run_wasm.js"; rc=$?
        if [ "$rc" != 0 ] && cat "$T/out" "$T/err" | grep -q 'Wasm host must initialize a unique __lang_thread_id'; then
          echo "  ok    wasm buffer $kind invalid worker identity $identity"
        else echo "  FAIL  wasm buffer $kind invalid worker identity $identity: status $rc"; fail=1; fi
      done
    else echo "  FAIL  wasm buffer $kind worker identities: $why"; fail=1; fi
  done
fi
expected=23
[ "$poison" = 1 ] && expected=36
[ "$checks" = "$expected" ] || { echo "  FAIL  wasm buffer: expected $expected checks, ran $checks"; fail=1; }
[ "$fail" = 0 ] || { echo "wasm_buffer_owner: FAILED"; exit 1; }
echo "wasm_buffer_owner: ok ($checks matrix, growth and negative-control checks, plus host/failure checks)"
