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

NAMES=$(sed -n 's/^let \(rec \)\{0,1\}\([a-z_][a-z_0-9]*\) *=.*/\2/p' "$ROOT/lib/rv_prelude.ml" \
        | grep -v '^contents$')
COUNT=$(printf '%s\n' $NAMES | wc -l | tr -d ' ')

# Probes, by shape. A name with no probe is reported: the point of the gate is
# that the list cannot drift from the prelude.
probe_for() {
  case "$1" in
    not) echo 'let _ = print_int (if not false then 1 else 0);' ;;
    is_digit|is_alpha|is_space) echo "let _ = print_int (if $1 \"5\" then 1 else 0);" ;;
    str_starts_with|str_ends_with|str_contains) echo "let _ = print_int (if $1 \"abc\" \"a\" then 1 else 0);" ;;
    str_index_of) echo 'let _ = print_int (str_index_of "abc" "b");' ;;
    str_repeat) echo 'let _ = print (str_repeat "ab" 2);' ;;
    str_rev|to_lower|to_upper) echo "let _ = print ($1 \"aB\");" ;;
    run) echo 'let _ = print_int (run "true");' ;;
    read_file) echo 'let _ = print (read_file "x");' ;;
    file_exists) echo 'let _ = print_int (if file_exists "x" then 1 else 0);' ;;
    time) echo 'let _ = print_int (float_bits_hi (time ()));' ;;
    random_int) echo 'let _ = print_int (random_int 10);' ;;
    write_file) echo 'let _ = write_file "a" "b";' ;;
    args) echo 'let _ = print_int (list_len (args ()));' ;;
    read_stdin) echo 'let _ = print (read_stdin ());' ;;
    bytes_of_str) echo 'let _ = print_bytes (bytes_of_str "x");' ;;
    print_bytes) echo 'let _ = print_bytes (bytes_of_str "x");' ;;
    __h_todo) echo '' ;;
    rvmap_clear|rvmap_compact|rvmap_recycle) echo "let m = rvmap_new ();\nlet _ = $1 m;\nlet _ = print_int 0;" ;;
    rvmap_bytes) echo 'let m = rvmap_new ();\nlet _ = print_int (rvmap_bytes m);' ;;
    rvvec_bytes) echo 'let v = vec_new ();\nlet _ = print_int (rvvec_bytes v);' ;;
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
# A Map key that is not a string: the prelude's Map is an assoc list comparing
# keys with `str_eq`, so a one-word constructor block is compared by reading its
# tag as a length. `map_get c Green` answered "key not found" for a key that was
# there.
printf 'type c = Red | Green;\nlet m = map_new ();\nlet _ = map_set m Green 1;\nlet _ = print_int (map_get m Green);\n' > "$TMP/mk.mere"
if "$MERE" -rv "$TMP/mk.mere" > /dev/null 2>"$TMP/mkerr"; then
  echo "FAIL rv_prelude: a non-str Map key was accepted (it is compared with str_eq)"
  rc=1
elif grep -q 'Map key of type' "$TMP/mkerr"; then :; else
  echo "FAIL rv_prelude: a non-str Map key was refused for the wrong reason"
  head -2 "$TMP/mkerr"
  rc=1
fi
# Ordering on a compound value: `==` has a generated structural helper, `<` does
# not, so it would compare the two heap pointers -- and since operands are
# allocated left then right, `a < b` came out true whichever way it was written.
printf 'type p = P of int;\nlet _ = print_bool (P 1 < P 2);\n' > "$TMP/ord.mere"
if "$MERE" -rv "$TMP/ord.mere" > /dev/null 2>"$TMP/orderr"; then
  echo "FAIL rv_prelude: ordering on a compound value was accepted (it compares pointers)"
  rc=1
elif grep -q 'would compare heap pointers' "$TMP/orderr"; then :; else
  echo "FAIL rv_prelude: compound ordering was refused for the wrong reason"
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
printf 'let _ = print_int (float_bits_hi (sqrt 2.0));\n' > "$TMP/op2.mere"
"$MERE" -rv "$TMP/op2.mere" > "$TMP/op2.bin" 2>/dev/null
if grep -a -q 'softfloat' "$TMP/op2.bin"; then :; else
  echo "FAIL rv_prelude: the f_add shim's message does not name softfloat"
  rc=1
fi
# And the exact phrase scripts/host_matrix.sh keys on to call these cells `stub`
# rather than `yes`. Rewording it silently turns 27 cells of that matrix into a
# claim the backend cannot honour, so the phrase is asserted here as well --
# a poison run reworded it and only the matrix noticed, which made this file's
# own comment about the coupling untrue.
# Both shim families must start their message with the prefix
# scripts/host_matrix.sh keys on to call a cell `stub` rather than `yes`. Losing
# it silently turns those cells into a claim the backend cannot honour: it
# happened once, when the host-service shims arrived with a different sentence
# and nine cells flipped.
printf 'let _ = print (read_file "x");\n' > "$TMP/op3.mere"
"$MERE" -rv "$TMP/op3.mere" > "$TMP/op3.bin" 2>/dev/null
for pair in "op2.bin:float" "op3.bin:host"; do
  f="$TMP/${pair%%:*}"; what="${pair##*:}"
  if grep -a -q 'RV32I:' "$f"; then :; else
    echo "FAIL rv_prelude: the $what shim's message lost the \`RV32I:\` prefix"
    echo "  (host_matrix.sh keys on it to say \`stub\` instead of \`yes\`)"
    rc=1
  fi
done

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
printf 'extern fn getpid: unit -> int;\nlet _ = print_int (getpid ());\n' > "$TMP/ex.mere"
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
printf 'extern fn getpid: unit -> int;\nlet _ = print "ok";\n' > "$TMP/exd.mere"
if "$MERE" -rv "$TMP/exd.mere" >/dev/null 2>&1; then :; else
  echo "FAIL rv_prelude: declaring an extern without calling it stops the program"
  rc=1
fi
# But an extern used as a VALUE is still refused: higher-order is unsupported
# here, so there is nothing to abort inside.
printf 'extern fn getpid: unit -> int;\nlet f = getpid;\nlet _ = print_int (f ());\n' > "$TMP/exv.mere"
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

# The count is the names written in lib/rv_prelude.ml. The prelude ALSO carries
# contrib/softfloat, spliced in from the generated lib/rv_softfloat.ml, and those
# names are not in this list -- scripts/softfloat_check.sh compiles all of them
# for RV32I. Saying "all names" here would have covered 76 that this gate never
# looked at.
[ "$rc" = 0 ] && echo "ok rv_prelude: all $COUNT hand-written prelude names compile for -rv, the float shims stop at runtime (softfloat's own names: softfloat_check.sh)"
exit $rc
