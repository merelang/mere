#!/bin/sh
# scripts/rv_prelude_check.sh — every name lib/rv_prelude.ml defines must be
# reachable through `mere -rv`, and the float ones must stop at RUNTIME with a
# message that says why.
#
# The prelude is injected by the driver, not by the backend, so test_basic.ml --
# which calls the backend directly -- cannot see it. Without this gate a name
# could be added to the prelude and never compiled by anything.
#
# The list is derived from the prelude source, so adding a definition without a
# probe fails here by name rather than passing unnoticed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "rv_prelude_check: $MERE not found — run 'dune build'" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0

# lib/rv_libm.ml is the prelude's tail (sin, cos, tan, atan2 and the libm the
# RISC-V backend binds libm-named externs to): hand-written too, so read with it
NAMES=$(cat "$ROOT/lib/rv_prelude.ml" "$ROOT/lib/rv_libm.ml" \
        | sed -n 's/^let \(rec \)\{0,1\}\([a-z_][a-z_0-9]*\) *=.*/\2/p' \
        | grep -v '^contents$' | grep -v '^builtin_contents$')
COUNT=$(printf '%s\n' $NAMES | wc -l | tr -d ' ')

# Probes, by shape. A name with no probe is reported: the point of the gate is
# that the list cannot drift from the prelude.
probe_for() {
  case "$1" in
    not) echo 'let _ = print_int (if not false then 1 else 0);' ;;
    # v0.1.653: reached through the builtins codegen lowers to them
    rvbb_new|rvbb_len) echo 'let b = bytebuf_new 3;
let _ = print_int (bytebuf_len b);' ;;
    rvbb_get|rvbb_set) echo 'let b = bytebuf_new 3;
let _ = bytebuf_set b 1 300;
let _ = print_int (bytebuf_get b 1);' ;;
    rvbb_push) echo 'let b = bytebuf_new 0;
let _ = bytebuf_push b 7;' ;;
    rvbb_to_bytes) echo 'let b = bytebuf_new 2;
let _ = print_int (bytes_len (bytes_of_bytebuf b));' ;;
    rvbb_of_bytes) echo 'let v = vec_of_bytes (bytes_of_str "ab");
let _ = print_int (vec_len v);' ;;
    rvlb_new|rvlb_push|rvlb_to_list) echo 'let b = lb_new ();
let _ = lb_push b 1;
let _ = print_int (list_len (lb_to_list b));' ;;
    rvov_get|rvov_copy) echo 'let o = owned_vec_new ();
let _ = owned_vec_push o 4;
let _ = print_int (owned_vec_get o 0 + vec_len (owned_vec_to_vec o));' ;;
    # v0.1.656: float32, fma, and the lane boxes the f64x2 / f32x4 builtins lower to
    f32_bits|float_of_f32_bits) echo 'let _ = print_int (f32_bits (float_of_f32_bits 1069547520));' ;;
    fma) echo 'let _ = print (str_of_float (fma 0.1 10.0 (0.0 - 1.0)));' ;;
    rvf2_*) echo 'let n = vec_new ();
let _ = vec_push n 1.0;
let _ = vec_push n 2.0;
let a = f64x2_add (f64x2_make 1.0 2.0) (f64x2_splat 0.5);
let b = f64x2_div (f64x2_mul (f64x2_sub a (f64x2_load n 0)) a) (f64x2_fma a a a);
let _ = f64x2_store n 0 b;
let _ = print (show b ++ to_json b);
let _ = print (str_of_float (f64x2_reduce_add b + f64x2_extract b 1));' ;;
    rvf4_*) echo 'let a = f32x4_add (f32x4_make 1.0 2.0 3.0 4.0) (f32x4_splat 0.1);
let b = f32x4_div (f32x4_mul (f32x4_sub a a) a) a;
let _ = print (show b ++ to_json b);
let _ = print (str_of_float (f32x4_reduce_add b + f32x4_extract b 3));' ;;
    u8x16_first_true|rvu16_show|rvu16_json) echo 'let v = u8x16_splat 3;
let _ = print_int (u8x16_first_true v);
let _ = print (show v ++ to_json v);' ;;
    # v0.1.659: the green threads and channels the thread builtins lower to
    rvth_*|rvch_*) echo 'let ch = channel_new ();
let h = spawn (fn (u: unit) -> channel_send ch 1);
let w = spawn (fn (u: unit) -> ());
let _ = channel_sender ch h;
let _ = print_int (channel_recv ch);
let _ = join h;
let _ = detach w;
let _ = print_int (list_len (par_map (fn (x: int) -> x) [1, 2]));
let _ = channel_close ch;
let _ = print (match channel_recv_opt ch with Some _ -> "s" | None -> "n");
let _ = print (match channel_recv_timeout ch 1 with Some _ -> "s" | None -> "n");' ;;
    # v0.1.642
    sys_os|sys_arch) echo "let _ = print ($1 ());" ;;
    # v0.1.640: every file builtin, in one program each (they need not run)
    file_open|file_openrw) echo "let f = $1 \"x\";
let _ = file_close f;" ;;
    file_close|file_fsync) echo "let f = file_openrw \"x\";
let _ = $1 f;" ;;
    file_read_line) echo 'let f = file_open "x";
let _ = print (match file_read_line f with | Some l -> l | None -> "-");' ;;
    file_pread) echo 'let f = file_open "x";
let _ = print_int (vec_len (file_pread f 0 4));' ;;
    file_pread_bytes) echo 'let f = file_open "x";
let _ = print_int (bytes_len (file_pread_bytes f 0 4));' ;;
    file_pwrite) echo 'let f = file_openrw "x";
let v = vec_new ();
let _ = vec_push v 1;
let _ = print_int (file_pwrite f 0 v);' ;;
    file_pwrite_bytes) echo 'let f = file_openrw "x";
let _ = print_int (file_pwrite_bytes f 0 (bytes_of_str "a"));' ;;
    read_file_bytes) echo 'let _ = print_int (vec_len (read_file_bytes "x"));' ;;
    write_file_bytes) echo 'let v = vec_new ();
let _ = write_file_bytes "x" v;' ;;
    write_bytes) echo 'let _ = write_bytes "x" (bytes_of_str "a");' ;;
    read_line) echo 'let _ = print (read_line ());' ;;
    read_lines) echo 'let _ = print_int (list_len (read_lines "x"));' ;;
    file_size) echo 'let _ = print_int (file_size "x");' ;;
    file_mtime) echo 'let _ = print_int (if file_mtime "x" > 0.0 then 1 else 0);' ;;
    list_dir) echo 'let _ = print_int (list_len (list_dir "x"));' ;;
    mkdir_p) echo 'let _ = mkdir_p "x/y";' ;;
    # v0.1.639
    rvshow_str) echo 'let _ = print (show "a");' ;;
    vec_to_list) echo 'let v = vec_new ();
let _ = vec_push v 1;
let _ = print_int (list_len (vec_to_list v));' ;;
    # v0.1.638
    print_bool) echo 'let _ = print_bool true;' ;;
    int_min|int_max) echo "let _ = print_int $1;" ;;
    bool_of_str) echo 'let _ = print_int (if bool_of_str "true" then 1 else 0);' ;;
    random_float) echo 'let _ = print_int (if random_float () < 1.0 then 1 else 0);' ;;
    rvlist_len) echo 'let _ = print_int (len (Cons (1, Nil)));' ;;
    str_count|str_last_index_of) echo "let _ = print_int ($1 \"abab\" \"ab\");" ;;
    utf8_chars) echo 'let _ = print_int (list_len (utf8_chars "ab"));' ;;
    vec_iter) echo 'let v = vec_new ();
let _ = vec_push v 1;
let _ = vec_iter v (fn (x: int) -> print_int x);' ;;
    vec_fold) echo 'let v = vec_new ();
let _ = vec_push v 1;
let _ = print_int (vec_fold v 0 (fn (a: int) -> fn (x: int) -> a + x));' ;;
    vec_sort) echo 'let v = vec_new ();
let _ = vec_push v 2;
let _ = vec_push v 1;
let _ = vec_sort v (fn (a: int) -> fn (b: int) -> a - b);' ;;
    sleep_ms) echo 'let _ = sleep_ms 1;' ;;
    # v0.1.623: the coroutine runtime, every entry at once
    rvcoro_*) echo 'let root = coro_root ();
let c = coro_new (fn me -> fn (n: int) -> let _ = print_int n in coro_exit root ());
let _ = coro_transfer c 1 root;
let _ = coro_scan_ints root 0 1 (fn (x: int) -> ());
let d = coro_new_sized 65536 (fn me -> fn (u: unit) -> coro_exit root ());
let _ = coro_switch d;' ;;
    is_digit|is_alpha|is_space) echo "let _ = print_int (if $1 \"5\" then 1 else 0);" ;;
    str_starts_with|str_ends_with|str_contains) echo "let _ = print_int (if $1 \"abc\" \"a\" then 1 else 0);" ;;
    str_index_of) echo 'let _ = print_int (str_index_of "abc" "b");' ;;
    str_repeat) echo 'let _ = print (str_repeat "ab" 2);' ;;
    str_rev|to_lower|to_upper) echo "let _ = print ($1 \"aB\");" ;;
    substring) echo 'let _ = print (substring "abcde" 1 3);' ;;
    pi|e) echo "let _ = print_int (float_bits_hi $1);" ;;
    run) echo 'let _ = print_int (run "true");' ;;
    read_file) echo 'let _ = print (read_file "x");' ;;
    read_bytes) echo 'let _ = print_int (bytes_len (read_bytes "x"));' ;;
    file_exists) echo 'let _ = print_int (if file_exists "x" then 1 else 0);' ;;
    file_delete) echo 'let _ = print_int (if file_delete "x" then 1 else 0);' ;;
    dir_create) echo 'let _ = print_int (dir_create "x" (0 - 1));' ;;
    dir_entries) echo 'let _ = print (dir_entries "x");' ;;
    dir_remove) echo 'let _ = print_int (dir_remove "x");' ;;
    env_pairs) echo 'let _ = print (env_pairs ());' ;;
    proc_cwd) echo 'let _ = print (proc_cwd ());' ;;
    utf8_len) echo 'let _ = print_int (utf8_len "aé");' ;;
    rvoob) echo 'let _ = print_int (try_or (fn (u: unit) -> rvoob 0 5 1 0) 7);' ;;
    env_var) echo 'let _ = print (match env_var "x" with | Some v -> v | None -> "-");' ;;
    __libm_proc_last_errno) echo 'let _ = print_int (__libm_proc_last_errno ());' ;;
    time) echo 'let _ = print_int (float_bits_hi (time ()));' ;;
    random_int) echo 'let _ = print_int (random_int 10);' ;;
    write_file) echo 'let _ = write_file "a" "b";' ;;
    args) echo 'let _ = print_int (list_len (args ()));' ;;
    read_stdin) echo 'let _ = print (read_stdin ());' ;;
    bytes_of_str) echo 'let _ = print_bytes (bytes_of_str "x");' ;;
    print_bytes) echo 'let _ = print_bytes (bytes_of_str "x");' ;;
    __h_todo) echo '' ;;
    rvmap_clear|rvmap_compact) echo "let m = rvmap_new ();\nlet _ = $1 m;\nlet _ = print_int 0;" ;;
    # v0.1.614: map_set's find / update / insert parts (codegen calls them)
    rvmap_upd) echo 'let m = rvmap_new ();\nlet _ = rvmap_set m "k" 1;\nlet _ = rvmap_upd m (_mslot m "k") 2;\nlet _ = print_int (rvmap_get m "k");' ;;
    rvmap_ins) echo 'let m = rvmap_new ();\nlet _ = rvmap_ins m (_mslot m "k") "k" 1;\nlet _ = print_int (rvmap_len m);' ;;
    rvmap_ins_i) echo 'let m = rvmap_new ();\nlet _ = rvmap_ins_i m (_mslot_i m 3) 3 1;\nlet _ = print_int (rvmap_get_i m 3);' ;;
    abs) echo 'let _ = print_int (abs (0 - 5));' ;;
    max|min|gcd) echo "let _ = print_int ($1 12 18);" ;;
    clamp) echo 'let _ = print_int (clamp 0 10 42);' ;;
    even|odd) echo "let _ = print_int (if $1 4 then 1 else 0);" ;;
    f_add|f_sub|f_mul|f_div|f_min|f_max|f_pow|atan2)
      echo "let _ = print_int (float_bits_hi ($1 1.5 2.5));" ;;
    f_neg|f_abs|sqrt|sin|cos|tan|log|exp|floor|ceil|round)
      echo "let _ = print_int (float_bits_hi ($1 1.5));" ;;
    f_lt|f_le|f_gt|f_ge) echo "let _ = print_int (if $1 1.5 2.5 then 1 else 0);" ;;
    float_of_int) echo 'let _ = print_int (float_bits_hi (float_of_int 3));' ;;
    int_of_float) echo 'let _ = print_int (int_of_float 1.5);' ;;
    float_of_str) echo 'let _ = print_int (float_bits_hi (float_of_str "1.5"));' ;;
    str_of_float) echo 'let _ = print (str_of_float 1.5);' ;;
    str_trim) echo 'let _ = print (str_trim "  x  ");' ;;
    str_join) echo 'let _ = print (str_join "," (Cons ("a", Cons ("b", Nil))));' ;;
    str_split) echo 'let _ = print_int (list_len (str_split "a,b" ","));' ;;
    str_replace) echo 'let _ = print (str_replace "aXa" "X" "-");' ;;
    str_unescape) echo 'let _ = print (str_unescape "plain");' ;;
    int_of_str) echo 'let _ = print_int (int_of_str "42");' ;;
    rvmap_new) echo 'let _ = print_int (if rvmap_has (rvmap_new ()) "k" then 1 else 0);' ;;
    rvmap_set) echo 'let m = rvmap_new ();\nlet _ = rvmap_set m "k" 1;\nlet _ = print_int 0;' ;;
    # `set` and `get` on the same map is a separate probe below, because doing
    # both in one program currently fails to type-check -- see the note there.
    rvmap_get) echo 'let m = rvmap_new ();\nlet _ = match rvmap_get m "k" with Some v -> print_int v | None -> print_int 0;' ;;
    rvmap_has) echo 'let _ = print_int (if rvmap_has (rvmap_new ()) "k" then 1 else 0);' ;;
    rvmap_delete) echo 'let m = rvmap_new ();\nlet _ = rvmap_delete m "k";\nlet _ = print_int 0;' ;;
    rvmap_len) echo 'let m = rvmap_new ();\nlet _ = print_int (rvmap_len m);' ;;
    rvmap_iter) echo 'let m = rvmap_new ();\nlet _ = rvmap_iter m (fn k -> fn v -> ());\nlet _ = print_int 0;' ;;
    # v0.1.599: the same Map with int (or bool) keys, compared with ==
    rvmap_get_i) echo 'let m = rvmap_new ();\nlet _ = print_int (rvmap_get_i m 1);' ;;
    rvmap_has_i) echo 'let _ = print_int (if rvmap_has_i (rvmap_new ()) 1 then 1 else 0);' ;;
    rvmap_delete_i) echo 'let m = rvmap_new ();\nlet _ = rvmap_delete_i m 1;\nlet _ = print_int 0;' ;;
    rvmap_set_i) echo 'let m = rvmap_new ();\nlet _ = rvmap_set_i m 1 2;\nlet _ = print_int (rvmap_get_i m 1);' ;;
    rvmap_len_i) echo 'let m = rvmap_new ();\nlet _ = print_int (rvmap_len_i m);' ;;
    rvmap_iter_i) echo 'let m = rvmap_new ();\nlet _ = rvmap_iter_i m (fn k -> fn v -> ());\nlet _ = print_int 0;' ;;
    *) echo "" ;;
  esac
}

MISSING=""
for n in $NAMES; do
  P="$(probe_for "$n")"
  if [ -z "$P" ]; then
    # A leading underscore marks an internal helper: it is reached through the
    # public name above it, and probing it directly would test nothing extra.
    case "$n" in
      _*|__f_todo|__h_todo) ;;
      *) MISSING="$MISSING $n" ;;
    esac
    continue
  fi
  # %b so a probe can be more than one line
  printf '%b\n' "$P" > "$TMP/p.mere"
  if ! "$MERE" -rv "$TMP/p.mere" > "$TMP/p.bin" 2> "$TMP/err"; then
    echo "FAIL rv_prelude: \`$n\` does not compile for -rv"
    head -3 "$TMP/err"
    rc=1
  fi
done
if [ -n "$MISSING" ]; then
  echo "FAIL rv_prelude: no probe for:$MISSING"
  echo "  (add one to probe_for in this script — an unprobed prelude name is"
  echo "   never compiled by anything, because the backend's own tests do not"
  echo "   see the prelude)"
  rc=1
fi

# A float operator must lower to a CALL into the prelude's softfloat wrapper.
# This assertion used to be its exact opposite -- that the operator reached the
# abort -- and checked it by looking for `li a7, 93` in the listing, which is the
# exit syscall that `_start`, __oom and __pat_fail all end with too. It was true
# of every program ever compiled by this backend.
# One needle per operator, so an operator wired to the wrong wrapper is caught
# rather than averaged away: a table that mapped Sub to __fadd would satisfy any
# check that only asked whether *some* softfloat call was emitted.
for pair in "+:__fadd" "-:__fsub" "*:__fmul" "/:__fdiv"; do
  op="${pair%%:*}"; fn="${pair##*:}"
  printf 'let _ = print_int (float_bits_hi (1.5 %s 2.5));\n' "$op" > "$TMP/op.mere"
  if "$MERE" -rvs "$TMP/op.mere" 2>/dev/null | grep -q "jal ra, u_$fn"; then :; else
    echo "FAIL rv_prelude: float $op did not lower to a call to $fn"
    rc=1
  fi
done
# ...and the named form has to reach the SAME implementation, not a second one.
printf 'let _ = print_int (float_bits_hi (f_add 1.5 2.5));\n' > "$TMP/opn.mere"
if "$MERE" -rvs "$TMP/opn.mere" 2>/dev/null | grep -q 'u___fadd'; then :; else
  echo "FAIL rv_prelude: f_add does not go through the same wrapper as float +"
  rc=1
fi
# Two things this backend REFUSES rather than answering wrongly. Nothing else
# gates them: scripts/rv_exec_check.sh skips a program that does not compile, so a
# refusal that was quietly deleted would turn back into a wrong answer with no
# test going red.
#
# A Map key that is not a string or a word. The prelude's Map compares keys
# with `str_eq` (or `==`), so a one-word constructor block was compared by
# reading its tag as a length: `map_get c Green` answered "key not found" for a
# key that was there. It was refused by name from then until v0.1.657, which
# rewrites such a Map into one keyed by `show k`. That needs one text per value,
# so a key with a float inside (C's == makes 0.0 and -0.0 one key, show makes
# them two) must still be REFUSED, and a constructor key must compile.
printf 'type c = Red | Green;\nlet m = map_new ();\nlet _ = map_set m Green 1;\nlet _ = print_int (map_get m Green);\n' > "$TMP/mk.mere"
if ! "$MERE" -rv "$TMP/mk.mere" > /dev/null 2>"$TMP/mkerr"; then
  echo "FAIL rv_prelude: a constructor Map key was refused (v0.1.657 rewrites it to a str key)"
  head -2 "$TMP/mkerr"
  rc=1
fi
printf 'let m = map_new ();\nlet _ = map_set m (1.5, 2) 1;\nlet _ = print_int (map_len m);\n' > "$TMP/mkf.mere"
if "$MERE" -rv "$TMP/mkf.mere" > /dev/null 2>"$TMP/mkerr"; then
  echo "FAIL rv_prelude: a Map key with a float inside was accepted (show would make 0.0 and -0.0 two keys)"
  rc=1
elif grep -q 'Map key of type' "$TMP/mkerr"; then :; else
  echo "FAIL rv_prelude: a Map key with a float inside was refused for the wrong reason"
  head -2 "$TMP/mkerr"
  rc=1
fi
# Ordering on a compound value (v0.1.655): a generated structural __cmp_<tag>,
# as `==` has its __eq_<tag>. It was refused here -- as a word the value is its
# heap pointer, and since operands are allocated left then right, `a < b` came
# out true whichever way it was written. That it orders by value is
# struct_eq_cmp's, in rv_exec on both widths; this holds that it compiles.
printf 'type p = P of int;\nlet _ = print_bool (P 2 < P 1);\n' > "$TMP/ord.mere"
if ! "$MERE" -rv "$TMP/ord.mere" > /dev/null 2>"$TMP/orderr"; then
  echo "FAIL rv_prelude: ordering on a compound value was refused"
  head -2 "$TMP/orderr"
  rc=1
fi

# Unary minus on a float is a sign-bit flip, not a two's-complement negate. The
# integer arm negates the word, which for a float is the pointer to its two
# halves, so before this it returned a wrong number quietly.
printf 'let x = 1.5;\nlet _ = print_int (float_bits_hi (-x));\n' > "$TMP/neg.mere"
if "$MERE" -rvs "$TMP/neg.mere" 2>/dev/null | grep -q 'u___fneg'; then :; else
  echo "FAIL rv_prelude: unary minus on a float did not go through softfloat"
  rc=1
fi

# The comparisons, one needle per operator. They live here and not in
# test/test_basic.ml because that harness types without the prelude, so the
# callee is not a known binding there and no call is emitted at all.
for pair in "<:__flt" "<=:__fle" ">:__fgt" ">=:__fge" "==:__feq" "!=:__fne"; do
  op="${pair%%:*}"; fn="${pair##*:}"
  printf 'let _ = print_int (if 1.5 %s 2.5 then 1 else 0);\n' "$op" > "$TMP/cmp.mere"
  if "$MERE" -rvs "$TMP/cmp.mere" 2>/dev/null | grep -q "u_$fn"; then :; else
    echo "FAIL rv_prelude: float $op did not lower to a call to $fn"
    rc=1
  fi
done

# A wired operator must not still be carrying the shim's apology. `__f_todo` is
# only reachable from a name that is genuinely not computed here, so its text
# appearing in an arithmetic-only binary means one of them was left unwired.
"$MERE" -rv "$TMP/opn.mere" > "$TMP/opn.bin" 2>/dev/null
if grep -a -q 'is not computed on this backend' "$TMP/opn.bin"; then
  echo "FAIL rv_prelude: f_add still reaches the not-computed shim"
  rc=1
fi
# The message lives in the binary's data, not in the instruction listing, so
# this looks at the bytes. `grep -a` because the file is binary and grep would
# otherwise say nothing at all rather than no.
# `sqrt` and not `f_add`: f_add is computed for real now, so it no longer has a
# message to check. What must still stop at run time is the set softfloat does
# not compute.
# The float functions are REAL now (v0.1.405): sqrt through softfloat's
# integer root, the transcendentals computed in the prelude. A shim message in
# that binary would mean a regression to the stub -- so the check inverted.
# scripts/host_matrix.sh keys on the `RV32I:` prefix to call a cell `stub`
# rather than `yes`; sqrt carrying one would flip its cell back to a claim the
# backend now honours for real.
printf 'let _ = print_int (float_bits_hi (sqrt 2.0));\n' > "$TMP/op2.mere"
"$MERE" -rv "$TMP/op2.mere" > "$TMP/op2.bin" 2>/dev/null
if grep -a -q 'RV32I: sqrt' "$TMP/op2.bin"; then
  echo "FAIL rv_prelude: sqrt carries a shim message again -- it is supposed to be computed"
  rc=1
fi
# The host-service stub, __h_todo, must keep the `RV32I:` prefix
# host_matrix.sh keys on. It happened once that a reworded shim sentence
# flipped nine matrix cells silently. Its last user was `run`, answered by
# memu's host device since v0.1.645; the stub stays for the next service a
# host cannot give, so it is called directly here.
printf 'let _ = print_int (__h_todo "probe" : int);\n' > "$TMP/op3.mere"
"$MERE" -rv "$TMP/op3.mere" > "$TMP/op3.bin" 2>/dev/null
if grep -a -q 'RV32I:' "$TMP/op3.bin"; then :; else
  echo "FAIL rv_prelude: the host shim's message lost the \`RV32I:\` prefix"
  echo "  (host_matrix.sh keys on it to say \`stub\` instead of \`yes\`)"
  rc=1
fi

# KNOWN, and pinned so it is noticed when it changes: using rvmap_set and
# rvmap_get on the SAME map fails to type-check, and the message blames the
# user for something that is bound --
#
#   let m = rvmap_new ();
#   let _ = rvmap_set m "k" 1;
#   let _ = match rvmap_get m "k" with Some v -> print_int v | None -> ();
#   => type error: unbound variable: rvmap_new
#
# Either function alone is fine, and it reproduces on the interpreter too, so it
# is not a backend hole. The pin expects the failure: when it starts compiling,
# this gate says so rather than staying quiet about a fixed bug.
printf 'let m = rvmap_new ();\nlet _ = rvmap_set m "k" 1;\nlet _ = match rvmap_get m "k" with Some v -> print_int v | None -> ();\n' > "$TMP/both.mere"
if "$MERE" -rv "$TMP/both.mere" > /dev/null 2>&1; then
  echo "FAIL rv_prelude: rvmap_set + rvmap_get now compiles — the pin above is stale, retire it"
  rc=1
fi

# An `extern fn` is a name the PROGRAM declared. Answering `unbound variable`
# for it blamed the user for a limit of the target -- the same shape as the
# builtin hole Q-070 closed, one declaration further out. This lives here rather
# than in test_basic.ml because that harness types the program itself and its
# typer answers `unbound variable` before codegen is reached.
# A CALL to an extern compiles and aborts at runtime naming the symbol. It used
# to be refused at compile time, and this gate asserted that -- correctly, until
# the behaviour changed underneath it and it said so. Refusing refuses the whole
# program for a call it may never make.
printf 'extern fn gethostid: unit -> int;\nlet _ = print_int (gethostid ());\n' > "$TMP/ex.mere"
if "$MERE" -rv "$TMP/ex.mere" > "$TMP/ex.bin" 2>"$TMP/exerr"; then
  if grep -a -q 'has no C library to link against' "$TMP/ex.bin"; then :; else
    echo "FAIL rv_prelude: an extern call compiled without the message that names why it will stop"
    rc=1
  fi
else
  echo "FAIL rv_prelude: an extern call no longer compiles for -rv"
  head -2 "$TMP/exerr"
  rc=1
fi
# A program that DECLARES one and never calls it must run.
printf 'extern fn gethostid: unit -> int;\nlet _ = print "ok";\n' > "$TMP/exd.mere"
if "$MERE" -rv "$TMP/exd.mere" >/dev/null 2>&1; then :; else
  echo "FAIL rv_prelude: declaring an extern without calling it stops the program"
  rc=1
fi
# But an extern used as a VALUE is still refused: higher-order is unsupported
# here, so there is nothing to abort inside.
printf 'extern fn gethostid: unit -> int;\nlet f = gethostid;\nlet _ = print_int (f ());\n' > "$TMP/exv.mere"
if "$MERE" -rv "$TMP/exv.mere" >/dev/null 2>"$TMP/exverr"; then
  echo "FAIL rv_prelude: an extern as a value compiled, and nothing can lower that"
  rc=1
fi
# and a name nobody declared is still a plain unbound variable, so the branch
# above did not swallow the ordinary case
printf 'let _ = print_int (nosuchname 1);\n' > "$TMP/tp.mere"
if "$MERE" -rv "$TMP/tp.mere" 2>&1 | grep -q 'unbound variable'; then :; else
  echo "FAIL rv_prelude: a genuine typo no longer reports as unbound"
  rc=1
fi

# v0.1.604: with two errors in the program, both are the program's lines. The
# report re-checks the file as it was given (no prelude in front), and those
# positions were moved again as if they counted from the prelude's top: every
# error was shown as `<rv-prelude>:N` with a prelude line under it.
printf 'let a = 1;\nlet b = missing_one + a;\nlet c = missing_two + b;\nprint_int c\n' > "$TMP/two.mere"
"$MERE" -rv "$TMP/two.mere" > /dev/null 2> "$TMP/twoerr"
if grep -q 'rv-prelude' "$TMP/twoerr" || [ "$(grep -c 'two.mere:[23]:9' "$TMP/twoerr")" != 2 ]; then
  echo "FAIL rv_prelude: two errors in the program are not both placed in it"
  grep -- '-->' "$TMP/twoerr" | head -3
  rc=1
fi

# v0.1.626: the parse's report had the same bug. Two syntax errors, or two
# `import`s that resolve nowhere (imports are resolved before the prelude is
# glued in front), were shown as `<rv-prelude>:N` with a prelude line under
# them. Each case is compared with what -c says about the same file; the lone
# import was right before and is kept, since the lone case changed path.
printf 'let a = 1;\nlet b = (a +;\nlet c = (b +;\n' > "$TMP/twosyn.mere"
printf 'let a = 1;\nlet b = 2;\nimport "nowhere/x.mere";\n' > "$TMP/oneimp.mere"
printf 'let a = 1;\nimport "nowhere/x.mere";\nimport "nowhere/y.mere";\n' > "$TMP/twoimp.mere"
for f in twosyn oneimp twoimp; do
  "$MERE" -c "$TMP/$f.mere" 2>&1 >/dev/null | grep -- '-->' > "$TMP/$f.c"
  "$MERE" -rv "$TMP/$f.mere" 2>&1 >/dev/null | grep -- '-->' > "$TMP/$f.rv"
  if [ ! -s "$TMP/$f.c" ] || grep -q 'rv-prelude' "$TMP/$f.rv" || ! cmp -s "$TMP/$f.c" "$TMP/$f.rv"; then
    echo "FAIL rv_prelude: $f.mere's parse errors are placed elsewhere under -rv than under -c"
    paste "$TMP/$f.c" "$TMP/$f.rv" | head -3
    rc=1
  fi
done

# The count is the names written in lib/rv_prelude.ml and lib/rv_libm.ml. The prelude ALSO carries
# contrib/softfloat, spliced in from the generated lib/rv_softfloat.ml, and those
# names are not in this list -- scripts/softfloat_check.sh compiles all of them
# for RV32I. Saying "all names" here would have covered 76 that this gate never
# looked at.
[ "$rc" = 0 ] && echo "ok rv_prelude: all $COUNT hand-written prelude names compile for -rv, and the float library is computed here (softfloat's own names: softfloat_check.sh)"
exit $rc
