#!/bin/sh
# scripts/owner_check.sh -- a container written by a thread other than the one
# that made it fails by name, on the interpreter, C and LLVM (v0.1.575),
# and for Vec (v0.1.680) and Map (v0.1.681) on the Node Wasm host.
#
# The type check (v0.1.574) follows what a spawned thread reaches through
# functions whose definitions it can see. A closure that arrives as a PARAMETER
# is not one of them -- a library that spawns the handler it was given cannot
# see what the handler touches -- and mere-blog's ledger race was exactly that.
# So Map, Vec, StrBuf, ByteBuf and ListBuf record the thread that made them, and
# a write from any other thread stops the program with one sentence instead of
# hanging a probe loop or losing entries.
#
# v0.1.582: and the OWNER may not write a container another thread has read.
# The first foreign read marks it shared, and a shared container is read-only
# for good -- that is what stops the owner churning a Map under a reader. A
# table built once and only read is still shared freely (legit, legit_readonly).
#
#   param_vec / param_map / param_strbuf   must fail, naming the operation
#   param_reverse     vec_reverse writes too (unchecked up to v0.1.578)
#   param_versioned   a write in a loop range-check versioning made unchecked:
#                     the guard asks __vec_owned, the checked copy fails
#   shared_map_race / shared_vec_race   the owner writes under a reader: the
#                     owner's write fails, naming it (the sentence is SHARED's)
#   shared_phase      read by a thread, joined, then written by the owner:
#                     refused too (the documented cost of the rule)
#   shared_versioned  the thread reads in a versioned loop, whose unchecked
#                     reads leave no mark -- the guard's vec_len is the mark
#   ov_param          an OwnedVec reached through a closure a launcher spawns:
#                     nothing moved it, so the thread's use fails by name
#   ov_after_move     moved into a thread, then used by the spawner through a
#                     function: the second user fails by name
#   ov_moved          moved into a thread by spawn's closure: must print 3
#   legit                                  must run and print 31
#   legit_readonly    tables read by three threads: must print two sums
#
# --poison removes each check from the emitted C and LLVM, and the program it
# guards must then stop failing that way (the interpreter's check is not in
# emitted text).
#
# Wasm covers Vec and Map here, with StrBuf/ByteBuf in wasm_buffer_owner_check.sh.
# ListBuf has its own wasm_listbuf_owner_check.sh matrix; OwnedVec handoff
# remains outside this runtime guarantee.
# Deterministic join/channel barriers cover shared
# containers, including two workers whose identities must differ. Generated cases
# exercise each read/write API, including range-versioned and SIMD paths.
#
# Usage: sh scripts/owner_check.sh [--poison] [--wasm-only]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "owner_check: $MERE not built" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "owner_check: no clang (LLVM IR needs it)" >&2; exit 2; }
for tool in node wat2wasm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "owner_check: no $tool (Wasm checks need it)" >&2; exit 2; }
done
poison=0; wasm_only=0
for arg in "$@"; do
  case "$arg" in --poison) poison=1 ;; --wasm-only) wasm_only=1 ;;
    *) echo "owner_check: unknown option $arg" >&2; exit 2 ;; esac
done
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/src"
cp "$ROOT"/test/owner/*.mere "$T/src/"
FX="$T/src"
SENT="made by one thread was written by another"
SHSENT="another thread has read was written"
OVSENT="an OwnedVec belongs to one thread"
sentence_of() { case "$1" in shared_*) echo "$SHSENT" ;; ov_*) echo "$OVSENT" ;; *) echo "$SENT" ;; esac; }
fail=0

run() { perl -e 'alarm 20; exec @ARGV' "$@" 2>&1; }

# $1 program, $2 c|ll|w, [$3 sed expression] -> $T/bin[.wasm]
build() {
  "$MERE" "-$2" "$FX/$1.mere" > "$T/g.$2" 2>"$T/e" || { echo "EMITFAIL $(head -1 "$T/e")"; return 1; }
  if [ -n "${3:-}" ]; then
    sed "$3" "$T/g.$2" > "$T/p.$2"
    cmp -s "$T/p.$2" "$T/g.$2" && { echo "SEDNOMATCH"; return 1; }
    mv "$T/p.$2" "$T/g.$2"
  fi
  if [ "$2" = w ]; then
    wat2wasm --enable-tail-call --enable-threads "$T/g.w" -o "$T/bin.wasm" 2>"$T/cc.err" || { echo "WATFAIL $(head -1 "$T/cc.err")"; return 1; }
  elif [ "$2" = c ]; then "$CC" -w -o "$T/bin" "$T/g.c" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(head -1 "$T/cc.err")"; return 1; }
  else clang -w -x ir -o "$T/bin" "$T/g.ll" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(grep -m1 error "$T/cc.err")"; return 1; }
  fi
}

judge() {  # $1 program, $2 output, $3 status -> ok or why not
  case "$1" in
    vec_caught|vec_recycle_caught) [ "$2" = '7:1' ] && [ "$3" = 0 ] && echo ok || echo "wanted caught failure without mutation, got [$2] status $3" ;;
    vec_alignment) [ "$2" = 272 ] && [ "$3" = 0 ] && echo ok || echo "wanted 272, got [$2] status $3" ;;
    shared_worker_ids)
      case "$2" in *"$SHSENT"*7) [ "$3" = 0 ] && echo ok || echo "join recovery exited $3" ;;
        *) echo "wanted a shared-write failure and recovered join, got [$2] status $3" ;; esac ;;
    ov_moved) [ "$2" = 3 ] && [ "$3" = 0 ] && echo ok || echo "printed [$(echo "$2" | head -1 | cut -c1-60)] status $3, wanted 3" ;;
    legit) [ "$2" = 31 ] && [ "$3" = 0 ] && echo ok || echo "printed [$(echo "$2" | head -1)] status $3, wanted 31" ;;
    legit_readonly) [ "$2" = "4495530
1498500" ] && [ "$3" = 0 ] && echo ok || echo "printed [$(echo "$2" | tr '\n' ' ' | cut -c1-60)] status $3" ;;
    *) case "$2" in *"$(sentence_of "$1")"*) [ "$3" != 0 ] && echo ok || echo "said it but exited 0" ;;
         *) echo "did not fail by name: [$(echo "$2" | head -1 | cut -c1-60)] status $3" ;; esac ;;
  esac
}

if [ "$wasm_only" = 0 ]; then
for f in param_vec param_map param_strbuf param_reverse param_versioned \
         shared_map_race shared_vec_race shared_phase shared_versioned \
         ov_param ov_after_move ov_moved legit legit_readonly \
         shared_vec_phase shared_worker_ids vec_caught vec_alignment \
         vec_recycle_caught shared_vec_recycle; do
  out=$(run "$MERE" "$FX/$f.mere"); st=$?
  v=$(judge "$f" "$out" "$st"); [ "$v" = ok ] && echo "  ok    interp $f" || { echo "  FAIL  interp $f: $v"; fail=1; }
  for be in c ll; do
    if ! why=$(build "$f" "$be"); then echo "  FAIL  $be $f: $why"; fail=1; continue; fi
    out=$(run "$T/bin"); st=$?
    v=$(judge "$f" "$out" "$st"); [ "$v" = ok ] && echo "  ok    $be $f" || { echo "  FAIL  $be $f: $v"; fail=1; }
  done
done

# Upkeep must reject foreign/shared writes before mutation on both Map layouts.
# Each generated callback is hidden behind a parameter, so the runtime guard
# rather than the static spawn check must enforce the rule.
upkeep_expect() {
  prog=$1; want=$2
  for be in interp c ll; do
    if [ "$be" = interp ]; then
      out=$(run "$MERE" "$FX/$prog.mere"); st=$?
    else
      if ! why=$(build "$prog" "$be"); then echo "  FAIL  $be $prog: $why"; fail=1; continue; fi
      out=$(run "$T/bin"); st=$?
    fi
    if [ "$st" = 0 ] && [ "$out" = "$want" ]; then echo "  ok    $be $prog"
    else echo "  FAIL  $be $prog: wanted [$want], got [$out] status $st"; fail=1; fi
  done
}
while IFS='|' read -r kind decl key1 key2; do
  decl=$(printf '%s' "$decl" | tr '@' '|')
  for op in clear recycle; do
    for access in foreign shared; do
      cat > "$FX/upkeep_$access-$kind-$op.mere" <<EOF
$decl
let k1 = $key1;
let k2 = $key2;
let mk = fn () -> let m = map_new () in let _ = map_set m k1 10 in m;
let m = mk ();
let launch = fn (f: unit -> unit) -> spawn f;
EOF
      if [ "$access" = foreign ]; then
        cat >> "$FX/upkeep_$access-$kind-$op.mere" <<EOF
let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or (fn () -> let _ = map_$op m in 0) 7));
let _ = join h;
let result = channel_recv results;
EOF
      else
        cat >> "$FX/upkeep_$access-$kind-$op.mere" <<EOF
let h = launch (fn () -> let _ = map_get m k1 in ());
let _ = join h;
let result = try_or (fn () -> let _ = map_$op m in 0) 7;
EOF
      fi
      cat >> "$FX/upkeep_$access-$kind-$op.mere" <<'EOF'
print (str_of_int result ++ ":" ++ str_of_int (map_len m) ++ ":" ++ (if map_has m k1 && map_get m k1 == 10 then "true" else "false"))
EOF
      upkeep_expect "upkeep_$access-$kind-$op" '7:1:true'
    done
    cat > "$FX/upkeep_local-$kind-$op.mere" <<EOF
$decl
let k1 = $key1;
let k2 = $key2;
let work = fn () ->
  let m = map_new () in
  let _ = map_set m k1 10 in let _ = map_set m k2 20 in
  let _ = map_delete m k1 in let _ = map_$op m in
  let empty = map_len m == 0 && not (map_has m k1) && not (map_has m k2) in
  let _ = map_$op m in
  let _ = map_set m k1 42 in
  let values = vec_new () in
  let _ = map_iter m (fn k -> fn v -> vec_push values v) in
  if empty && map_len m == 1 && vec_len values == 1 then vec_get values 0 else 0;
let results = channel_new ();
let h = spawn (fn () -> channel_send results (work ()));
let own = work ();
let _ = join h;
print_int (own + channel_recv results)
EOF
    upkeep_expect "upkeep_local-$kind-$op" 84
    # If the upkeep guard alone is removed, the subsequent map_set must still
    # see the shared bit. Resetting the owner as well must make it succeed.
    cat > "$FX/upkeep_retained-$kind-$op.mere" <<EOF
$decl
let k1 = $key1;
let mk = fn () -> let m = map_new () in let _ = map_set m k1 10 in m;
let m = mk ();
let launch = fn (f: unit -> unit) -> spawn f;
let h = launch (fn () -> let _ = map_get m k1 in ());
let _ = join h;
let _ = map_$op m;
let _ = map_set m k1 7;
print_int (map_get m k1)
EOF
  done
done <<'UPKEEP_KEYS'
int||1|2
str||"one"|"two"
bool||false|true
tuple||(1, "one")|(2, "two")
record|type key = { kx: int, kname: str };|key { kx = 1, kname = "one" }|key { kx = 2, kname = "two" }
variant|type key = First of int @ Second of str;|First 1|Second "two"
UPKEEP_KEYS
upkeep_expect map_upkeep_growth 84

fi

wasm_cases='param_vec param_map shared_phase param_reverse param_versioned shared_versioned legit legit_readonly ov_moved shared_vec_phase shared_worker_ids vec_caught vec_alignment vec_recycle_caught shared_vec_recycle'
# Each reader is the only foreign access before join and the owner's write.
# If its mark disappears, that write succeeds and this case goes red.
while IFS='|' read -r name expr; do
  [ -n "$name" ] || continue
  cat > "$FX/shared_api_$name.mere" <<EOF
let mk = fn () -> let v = vec_new () in let _ = vec_push v 1 in let _ = vec_push v 2 in v;
let v = mk ();
let launch = fn (f: unit -> unit) -> spawn f;
let h = launch (fn () -> let _ = $expr in ());
let _ = join h;
vec_push v 3
EOF
  wasm_cases="$wasm_cases shared_api_$name"
done <<'READERS'
get|vec_get v 0
len|vec_len v
clone|vec_to_owned v
concat|vec_concat v v
iter|vec_iter v (fn x -> ())
fold|vec_fold v 0 (fn a -> fn b -> a + b)
map|vec_map v (fn x -> x + 1)
filter|vec_filter v (fn x -> x > 0)
to_list|vec_to_list v
bytes|bytes_of_vec v
READERS
while IFS='|' read -r name expr; do
  [ -n "$name" ] || continue
  cat > "$FX/write_api_$name.mere" <<EOF
let mk = fn () -> let v = vec_new () in let _ = vec_push v 1 in let _ = vec_push v 2 in v;
let v = mk ();
let launch = fn (f: unit -> unit) -> spawn f;
let h = launch (fn () -> $expr);
join h
EOF
  wasm_cases="$wasm_cases write_api_$name"
done <<'WRITERS'
set|vec_set v 0 3
sort|vec_sort v (fn a -> fn b -> a - b)
WRITERS
for op in load store; do
  if [ "$op" = load ]; then expr='let _ = f64x2_extract (f64x2_load v 0) 0 in ()'; name=shared_simd; tail='vec_push v 3.0'
  else expr='f64x2_store v 0 (f64x2_splat 3.0)'; name=write_simd; tail='()'; fi
  cat > "$FX/$name.mere" <<EOF
let mk = fn () -> let v = vec_new () in let _ = vec_push v 1.0 in let _ = vec_push v 2.0 in v;
let v = mk ();
let launch = fn (f: unit -> unit) -> spawn f;
let h = launch (fn () -> $expr);
let _ = join h;
$tail
EOF
  wasm_cases="$wasm_cases $name"
done
for f in $wasm_cases; do
  if ! why=$(build "$f" w); then echo "  FAIL  wasm $f: $why"; fail=1; continue; fi
  out=$(run node "$ROOT/scripts/run_wasm.js" "$T/bin.wasm"); st=$?
  v=$(judge "$f" "$out" "$st"); [ "$v" = ok ] && echo "  ok    wasm $f" || { echo "  FAIL  wasm $f: $v"; fail=1; }
done

cp "$ROOT/test/range_version/sum_curried.mere" "$FX/vec_unthreaded.mere"
if why=$(build vec_unthreaded w); then
  out=$(run node "$ROOT/scripts/run_wasm.js" "$T/bin.wasm"); st=$?
  if [ "$out" = 84 ] && [ "$st" = 0 ] && ! grep -Eq 'atomic\.|\$mere_vec_(read|write|owner_ok)|__lang_thread_id' "$T/g.w"; then
    echo "  ok    wasm without spawn: range-versioned reads, no owner checks or atomics"
  else echo "  FAIL  wasm without spawn: [$out] status $st, or ownership code remains"; fail=1; fi
else echo "  FAIL  wasm without spawn: $why"; fail=1; fi

if [ "$poison" = 1 ]; then
  pf=0
  # a poison either removes a check (the race must then go through unnoticed)
  # or removes a hand-over (prog ov_moved: the legitimate move must then fail)
  if [ "$wasm_only" = 0 ]; then
  while IFS='|' read -r prog be what expr; do
    [ -n "$be" ] || continue
    if ! why=$(build "$prog" "$be" "$expr"); then echo "  FAIL  POISON $be ($what): $why"; pf=1; continue; fi
    out=$(run "$T/bin"); st=$?
    case "$prog" in
      ov_moved)
        case "$out" in *"$OVSENT"*) echo "  ok    POISON $be ($what): the moved OwnedVec is refused" ;;
          *) echo "  FAIL  POISON $be ($what): the move still works -- the gate does not witness the hand-over"; pf=1 ;; esac ;;
      *)
        case "$out" in *"$(sentence_of "$prog")"*) echo "  FAIL  POISON $be ($what): still fails by name -- the gate does not witness the check"; pf=1 ;;
          *) echo "  ok    POISON $be ($what): the race goes through unnoticed" ;; esac ;;
    esac
  done <<'POISONS'
param_vec|c|the C check is gone|s/^#define __LANG_OWNED(c, k, o) .*/#define __LANG_OWNED(c, k, o) ((void)0)/
param_versioned|c|the versioning guard does not ask|s/^#define __LANG_OWNER_OK(c) .*/#define __LANG_OWNER_OK(c) 1/
param_vec|ll|the LLVM check is gone|/call void @__lang_owned(i32/d
param_reverse|ll|vec_reverse is not checked|/call void @__lang_owned(i32 .*@.own_vec_vec_reverse,/d
shared_phase|c|a read leaves no mark|s/^#define __LANG_READ(c) .*/#define __LANG_READ(c) ((void)0)/
shared_phase|c|the write does not say why|/if (owner == (__lang_tid() | __LANG_SHARED)) __lang_shared_fail(kind, op);/d
shared_versioned|c|the guard's vec_len leaves no mark|s/_len(mere_vec_int\* v) { __LANG_READ(v); return/_len(mere_vec_int* v) { return/
shared_phase|ll|a read leaves no mark|/call void @__lang_read_mark(ptr %__rd_p)/d
ov_param|c|OwnedVec use is not checked|s/^  __lang_ov_fail(op);$//
ov_moved|c|spawn does not give the OwnedVec away|s/(mu_g)->owner = 0; //
ov_param|ll|OwnedVec use is not checked|/call void @__lang_ov_use(ptr/d
ov_moved|ll|spawn does not give the OwnedVec away|/store atomic i32 0, ptr %t[0-9]* monotonic, align 4/d
shared_versioned|ll|the guard's vec_len leaves no mark|/^define i64 @mere_vec_int_len(/,/^}/{/call void @__lang_read_mark/d;}
POISONS
  for op in clear recycle; do
    for kind in int tuple; do
      drop="/call void @__lang_owned(i32 .*@.own_map_map_$op,/d"
      prog="upkeep_foreign-$kind-$op"
      if why=$(build "$prog" ll "$drop"); then
        out=$(run "$T/bin"); st=$?
        if [ "$st" = 0 ] && [ "$out" = '0:0:false' ]; then echo "  ok    POISON LLVM $kind map_$op: foreign mutation succeeds"
        else echo "  FAIL  POISON LLVM $prog: [$out] status $st"; pf=1; fi
      else echo "  FAIL  POISON LLVM $prog: $why"; pf=1; fi
      prog="upkeep_retained-$kind-$op"
      if why=$(build "$prog" ll "$drop"); then
        out=$(run "$T/bin"); st=$?
        case "$out" in
          *"map_set: a Map $SHSENT"*)
            if [ "$st" != 0 ]; then echo "  ok    LLVM $kind map_$op preserves shared metadata without its entry check"
            else echo "  FAIL  LLVM $prog: shared write exited 0"; pf=1; fi ;;
          *) echo "  FAIL  LLVM $prog: expected shared map_set failure, got [$out] status $st"; pf=1 ;;
        esac
      else echo "  FAIL  LLVM $prog: $why"; pf=1; fi
      # The mutation is confined to the public wrapper, where %__own_p is the
      # original header's owner address. The storage helper never touches it.
      reset="$drop
/^define i32 @mere_map_.*_$op(/,/^}/{
/call void @mere_map_.*_clear_storage(ptr %m)/a\\
  store atomic i32 1, ptr %__own_p monotonic, align 4
}"
      if why=$(build "$prog" ll "$reset"); then
        out=$(run "$T/bin"); st=$?
        if [ "$st" = 0 ] && [ "$out" = 7 ]; then echo "  ok    POISON LLVM $kind map_$op resets shared metadata: later write succeeds"
        else echo "  FAIL  POISON LLVM $prog owner reset: [$out] status $st"; pf=1; fi
      else echo "  FAIL  POISON LLVM $prog owner reset: $why"; pf=1; fi
    done
  done
  if why=$(build vec_recycle_caught ll '/call void @__lang_owned(i32 .*@.own_vec_vec_recycle,/d'); then
    out=$(run "$T/bin"); st=$?
    if [ "$st" = 0 ] && [ "$out" = '0:0' ]; then echo "  ok    POISON LLVM vec_recycle: foreign mutation succeeds"
    else echo "  FAIL  POISON LLVM vec_recycle: [$out] status $st"; pf=1; fi
  else echo "  FAIL  POISON LLVM vec_recycle: $why"; pf=1; fi
  fi
  # These mutations must still assemble, run and produce the wrong successful
  # result. A syntax error, trap or timeout does not witness an ownership gate.
  while IFS='|' read -r prog expr; do
    if ! why=$(build "$prog" w "$expr"); then echo "  FAIL  POISON wasm $prog: $why"; pf=1; continue; fi
    out=$(run node "$ROOT/scripts/run_wasm.js" "$T/bin.wasm"); st=$?
    case "$out" in *"$(sentence_of "$prog")"*) st=1 ;; esac
    if [ "$st" = 0 ]; then echo "  ok    POISON wasm $prog: unchecked access succeeds"
    else echo "  FAIL  POISON wasm $prog: expected successful unchecked access, status $st"; pf=1; fi
  done <<'WASM_POISONS'
param_vec|/call $mere_vec_write.*;; vec-owner$/d
shared_vec_phase|/call $mere_vec_read.*;; vec-owner$/d
shared_vec_recycle|/call $mere_vec_write.*i32.const 5.*;; vec-owner$/d
WASM_POISONS
  mkdir "$T/host"
  cp "$ROOT"/scripts/*.js "$T/host/"
  if why=$(build shared_worker_ids w); then
    # Delay the diagnostic to make a premature completion observable on every
    # run: join must wait for the line before it can terminate the worker.
    sed '/fs.writeSync(2, "mere: thread " + tid/i\
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    cp "$T/host/run_wasm.js" "$T/delayed-host.js"
    out=$(run node "$T/host/run_wasm.js" "$T/bin.wasm"); st=$?
    v=$(judge shared_worker_ids "$out" "$st")
    [ "$v" = ok ] && echo "  ok    wasm delayed diagnostic: join waits for the line" || { echo "  FAIL  wasm delayed diagnostic: $v"; pf=1; }
    # Publish and notify completion before the delayed line: the ownership
    # error reaches join, but the worker is terminated without its reason.
    sed '/Atomics.store(st, 0, 1);/d; /Atomics.wait(new Int32Array(new SharedArrayBuffer(4))/i\
    Atomics.store(st, 0, 1); Atomics.notify(st, 0);' "$T/delayed-host.js" > "$T/host/run_wasm.js"
    out=$(run node "$T/host/run_wasm.js" "$T/bin.wasm"); st=$?
    if [ "$out" = 7 ] && [ "$st" = 0 ]; then echo "  ok    POISON wasm premature completion: diagnostic is lost"
    else echo "  FAIL  POISON wasm premature completion: [$out] status $st"; pf=1; fi
    sed 's/__lang_thread_id.value = tid + 1/__lang_thread_id.value = 2/' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    out=$(run node "$T/host/run_wasm.js" "$T/bin.wasm"); st=$?
    if [ "$out" = 0 ] && [ "$st" = 0 ]; then echo "  ok    POISON wasm duplicate worker IDs: shared write succeeds"
    else echo "  FAIL  POISON wasm duplicate worker IDs: [$out] status $st"; pf=1; fi
  else echo "  FAIL  POISON wasm worker identities: $why"; pf=1; fi
  cp "$ROOT/test/threadfail/join_caught.mere" "$FX/diagnostic_write.mere"
  if why=$(build diagnostic_write w); then
    # This host keeps the successful-write ordering but loses completion when
    # a diagnostic throws. First prove it still runs an ordinary failed join.
    sed 's/^  } finally {$/  } catch (error) { throw error; } {/' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    sh "$ROOT/scripts/bounded.sh" 5 node "$T/host/run_wasm.js" "$T/bin.wasm" > "$T/out" 2> "$T/err"; st=$?
    if [ "$(cat "$T/out")" = 7 ] && [ "$st" = 0 ]; then
      echo "  ok    wasm without finally: ordinary failed join still recovers"
    else echo "  FAIL  wasm without finally: ordinary join status $st"; pf=1; fi
    # Inject an EPIPE at the worker's diagnostic write. Its recorded Mere
    # failure must still reach try_or in the parent, which prints 7.
    sed '/^const st = new Int32Array(doneSab, 0, 5);$/a\
const writeSync = fs.writeSync; fs.writeSync = (fd, ...args) => { if (fd === 2) throw Object.assign(new Error("diagnostic write failed"), { code: "EPIPE" }); return writeSync(fd, ...args); };' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    sh "$ROOT/scripts/bounded.sh" 5 node "$T/host/run_wasm.js" "$T/bin.wasm" > "$T/out" 2> "$T/err"; st=$?
    if [ "$(cat "$T/out")" = 7 ] && [ "$st" = 0 ]; then
      echo "  ok    wasm throwing diagnostic write: join recovers"
    else echo "  FAIL  wasm throwing diagnostic write: status $st, stdout [$(cat "$T/out")]"; pf=1; fi
    sed 's/^  } finally {$/  } catch (error) { throw error; } {/' "$T/host/run_wasm.js" > "$T/throw-no-finally.js"
    mv "$T/throw-no-finally.js" "$T/host/run_wasm.js"
    sh "$ROOT/scripts/bounded.sh" 3 node "$T/host/run_wasm.js" "$T/bin.wasm" > "$T/out" 2> "$T/err"; st=$?
    if [ "$st" = 201 ] && [ ! -s "$T/out" ]; then
      echo "  ok    POISON wasm throwing diagnostic without finally: join times out"
    else echo "  FAIL  POISON wasm throwing diagnostic without finally: status $st, stdout [$(cat "$T/out")]"; pf=1; fi
  else echo "  FAIL  wasm throwing diagnostic: $why"; pf=1; fi
  if why=$(build param_vec w); then
    sed '/__lang_thread_id.value = tid + 1/d' "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
    out=$(run node "$T/host/run_wasm.js" "$T/bin.wasm"); st=$?
    case "$out" in *'Wasm host must initialize a unique __lang_thread_id'*)
      [ "$st" = 1 ] && echo "  ok    wasm host without worker identity: refused by name" || { echo "  FAIL  wasm missing identity exited $st"; pf=1; } ;;
      *) echo "  FAIL  wasm host without worker identity: [$out] status $st"; pf=1 ;; esac
    for identity in 0 1073741824 -1; do
      sed "s/__lang_thread_id.value = 1;/__lang_thread_id.value = $identity;/" "$ROOT/scripts/run_wasm.js" > "$T/host/run_wasm.js"
      out=$(run node "$T/host/run_wasm.js" "$T/bin.wasm"); st=$?
      case "$out" in *'Wasm host must initialize a unique __lang_thread_id'*)
        [ "$st" = 1 ] && echo "  ok    wasm invalid identity $identity: refused by name" || { echo "  FAIL  wasm invalid identity $identity exited $st"; pf=1; } ;;
        *) echo "  FAIL  wasm invalid identity $identity: [$out] status $st"; pf=1 ;; esac
    done
  else echo "  FAIL  wasm missing worker identity: $why"; pf=1; fi
  if why=$(build vec_alignment w '/local.set $v (i32.and.*;; vec-owner$/d'); then
    out=$(run node "$ROOT/scripts/run_wasm.js" "$T/bin.wasm"); st=$?
    case "$out" in *'unaligned accesses'*)
      [ "$st" = 1 ] && echo "  ok    POISON wasm alignment: unaligned atomic access traps" || { echo "  FAIL  POISON wasm alignment exited $st"; pf=1; } ;;
      *) echo "  FAIL  POISON wasm alignment: [$out] status $st"; pf=1 ;; esac
  else echo "  FAIL  POISON wasm alignment: $why"; pf=1; fi
  [ "$pf" = 0 ] || { echo "owner_check --poison: FAILED"; exit 1; }
fi
[ "$fail" = 0 ] || { echo "owner_check: FAILED"; exit 1; }
if [ "$poison" = 1 ]; then echo "owner_check --poison: ok (the gate can go red)"; else echo "owner_check: ok"; fi
