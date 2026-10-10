#!/bin/sh
# scripts/region_uaf_check.sh -- a value that outlives the block it was made in,
# by a route the types do not see, must still be there when it is read.
#
# WHY A SECOND GATE NEXT TO escape_check. escape_check runs test/escape/ROUTES
# and compares VERDICTS: does each backend accept or refuse the program. A SAFE
# row is accepted, and nothing there asks whether the accepted program then
# reads the right bytes. Four routes were accepted, safe by every verdict, and
# use-after-free at run time:
#
#   kept_then_written    (Q-190, v0.1.563) a container retained by v0.1.557 and
#                        WRITTEN after its block -- the block's struct was
#                        recycled, so the writes went into the next block
#   spawn_env_in_block   (Q-191, v0.1.564) a thread handed its closure's env as
#                        it was, read after the block was reused
#   ownedvec_store       (Q-192, v0.1.564) owned_vec_push stored a str as the
#                        pointer it was
#   channel_from_block   (v0.1.564, LLVM) a message sent as the pointer it was
#   recycled_escape      (Q-195, v0.1.567) a Map given its own arena by map_recycle,
#                        captured by a closure: retention asked about the arena and
#                        not about the block the map's struct lives in
#
# plus coro_env_from_block, which was right already (v0.1.558) and is here so
# that it stays right, and
#
#   channel_xthread      (v0.1.619, C) a channel message's region is made by the
#                        sender and freed by the receiver, and its blocks sat on
#                        the sender's thread-local list (v0.1.549): the receiver
#                        unlinked them from its own, and the sender's next
#                        message wrote into the freed one
#
# So this gate RUNS each program, after making the block's memory be reused (the
# churn in each program), on the interpreter -- which has no arenas and is the
# answer -- and on C and LLVM, and requires the same output. The v0.1.557
# witness for Q-188 only READ the escaped value afterwards, which is why Q-190
# survived it: a lifetime fix has to be witnessed by a write, too.
#
# --poison undoes each fix in the emitted code, one at a time, and the program
# that exists for it must go red. A poison that frees something has to wreck it
# first: whether a program notices a freed struct is the allocator's business.
# The LLVM `kept_then_written` poison only freed the struct up to v0.1.568, and
# on glibc the struct's bytes were still there to be used -- green on Linux, red
# on macOS, and CI red for six versions. It now fills the struct with 0xAA..
# before the free (a poison written `perl:` is run by perl, which can add a line).
#
# Usage: sh scripts/region_uaf_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "region_uaf: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "region_uaf: no C compiler" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# A spawned thread gets an alternate signal stack of the runtime's own (Q-178);
# ASan on macOS would try to unmap it as if it were ASan's when the thread ends.
# Leaks are not what this gate asks about (a channel is never freed).
ASAN_OPTIONS="${ASAN_OPTIONS:-use_sigaltstack=0:detect_leaks=0}"; export ASAN_OPTIONS
FX="$ROOT/test/uaf"
MODE="${1:-}"
fail=0

# program | backends (c C, l LLVM)
CASES='kept_then_written|cl
spawn_env_in_block|c
ownedvec_store|cl
channel_from_block|cl
coro_env_from_block|c
recycled_escape|c
recycle_dedicated|ca
coro_pin_reach|ca
coro_pin_resumed|ca
vec_recycle_pin|ca
channel_xthread|ca'

run_bin() { perl -e 'alarm 20; exec @ARGV' "$1" 2>&1; }
# v0.1.641: a poisoned program runs with the allocator scribbling what is freed
# (macOS MallocScribble, glibc MALLOC_PERTURB_), so a use after free reads
# garbage whether or not the block was handed out again -- "ll
# channel_from_block" stayed green on 1 run of 61 when it was not. Any line the
# allocator prints about it is not the program's.
run_poisoned() { env MallocScribble=1 MALLOC_PERTURB_=85 perl -e 'alarm 20; exec @ARGV' "$1" 2>&1 | grep -v 'malloc: enabling scribbling'; }

build() {  # $1 = program, $2 = c|ll, [$3 = sed expression] -> $T/bin, or prints why not
  "$MERE" "-$2" "$FX/$1.mere" > "$T/g.$2" 2>"$T/emit.err" || { echo "EMITFAIL $(head -1 "$T/emit.err")"; return 1; }
  if [ -n "${3:-}" ]; then
    case "$3" in
      perl:*) perl -pe "${3#perl:}" "$T/g.$2" > "$T/p.$2" ;;
      *) sed "$3" "$T/g.$2" > "$T/p.$2" ;;
    esac
    if cmp -s "$T/p.$2" "$T/g.$2"; then echo "SEDNOMATCH"; return 1; fi
    mv "$T/p.$2" "$T/g.$2"
  fi
  if [ "$2" = c ]; then lang=c; else lang=ir; fi
  # a case marked `a` is built with ASan: what it guards against is a write past
  # a malloc'd block, which only a sanitizer turns into an answer
  san=""; case "${4:-}" in *a*) san="-fsanitize=address -g" ;; esac
  # shellcheck disable=SC2086
  "$CC" -w $san -x "$lang" -o "$T/bin" "$T/g.$2" -lm -lpthread 2>"$T/cc.err" || { echo "CCFAIL $(head -1 "$T/cc.err")"; return 1; }
}

printf '%s\n' "$CASES" | while IFS='|' read -r f b; do
  want=$("$MERE" "$FX/$f.mere" 2>&1)
  case "$want" in
    *ZZZZ*|"") printf '  FAIL  %s\n' "interp $f: the answer itself looks wrong: $want"; echo x >> "$T/failed"; continue ;;
  esac
  for be in c ll; do
    case "$be" in c) letter=c; name=C ;; ll) letter=l; name=LLVM ;; esac
    case "$b" in *"$letter"*) ;; *) continue ;; esac
    if ! why=$(build "$f" "$be" "" "$b"); then printf '  FAIL  %s\n' "$name $f: $why"; echo x >> "$T/failed"; continue; fi
    got=$(run_bin "$T/bin")
    if [ "$got" = "$want" ]; then printf '  ok    %s\n' "$name $f"
    else printf '  FAIL  %s\n' "$name $f: got [$(echo "$got" | head -1 | cut -c1-40)] wanted [$(echo "$want" | head -1 | cut -c1-40)]"; echo x >> "$T/failed"; fi
  done
done
[ -f "$T/failed" ] && fail=1

if [ "$MODE" = --poison ]; then
  # program | backend | what the poison undoes | sed expression
  POISONS='kept_then_written|c|a kept struct is recycled again|s/    r->fwd = t;//
kept_then_written|ll|a kept struct is freed again|perl:s/^  br i1 %none, label %freestruct, label %leave$/  br label %freestruct/; s/^freestruct:$/freestruct:\n  store [6 x i64] [i64 -6148914691236517206, i64 -6148914691236517206, i64 -6148914691236517206, i64 -6148914691236517206, i64 -6148914691236517206, i64 -6148914691236517206], ptr %r/
spawn_env_in_block|c|the thread gets the env as it was|s/__se = __sh->__copy(&__lang_default_region, __se);/(void)0;/
ownedvec_store|c|owned_vec_push stores the pointer|s/v->data\[v->len++\] = __mcopy_str(&__lang_default_region, x);/v->data[v->len++] = x;/
ownedvec_store|ll|owned_vec_push stores the pointer|s/= call ptr @__mcopy_str(ptr @__lang_default_region, ptr \(%t[0-9]*\))/= getelementptr i8, ptr \1, i64 0/
channel_from_block|ll|the message is sent as the pointer|s/= call ptr @__mcopy_str(ptr @__lang_default_region, ptr \(%t[0-9]*\))/= getelementptr i8, ptr \1, i64 0/
recycled_escape|c|only the moved storage is kept, not where the struct lives|s/ __lang_region_keep(v->home, r); / /
recycle_dedicated|c|a recycle claims 4 KB on the block it kept|s/^    r->cap = b->pad;$/    r->cap = 4096;/
coro_pin_reach|c|the pin reads the stack and not what it points at|s/^  __lang_pin_reach(c);$//
coro_pin_resumed|c|a retired arena is tried while its pinner runs|s/if (o.by\[j\] == curh) keep = 1;//
vec_recycle_pin|c|vec_recycle asks the pin about the growth only, as map_recycle does|s/__lang_region_pinned(v->region, 0)) {/__lang_region_pinned(v->region, 1) \&\& v->region->blocks->prev) {/
channel_xthread|c|a message region goes on the list of the thread that made it|s/__lang_region_init_x(mr, 256, 1)/__lang_region_init_x(mr, 256, 0)/'
  printf '%s\n' "$POISONS" | while IFS='|' read -r f be what expr; do
    want=$("$MERE" "$FX/$f.mere" 2>&1)
    flags=$(printf '%s\n' "$CASES" | grep "^$f|" | cut -d'|' -f2)
    if ! why=$(build "$f" "$be" "$expr" "$flags"); then printf '  FAIL  %s\n' "POISON $be $f ($what): $why"; echo x >> "$T/pfailed"; continue; fi
    got=$(run_poisoned "$T/bin")
    if [ "$got" != "$want" ]; then printf '  ok    %s\n' "POISON $be $f ($what): goes red"
    else printf '  FAIL  %s\n' "POISON $be $f ($what): still green -- the program does not witness the fix"; echo x >> "$T/pfailed"; fi
  done
  [ -f "$T/pfailed" ] && { echo "region_uaf --poison: FAILED"; exit 1; }
fi

if [ "$fail" != 0 ]; then echo "region_uaf: FAILED"; exit 1; fi
if [ "$MODE" = --poison ]; then echo "region_uaf --poison: ok (the gate can go red)"; else echo "region_uaf: ok"; fi
