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
      _*|__f_todo) ;;
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

# The float shims must be a RUNTIME stop, not a compile error, and must name
# what is missing. `li a7, 93` is the exit syscall the abort ends with.
printf 'let _ = print_int (float_bits_hi (1.5 + 2.5));\n' > "$TMP/op.mere"
if "$MERE" -rvs "$TMP/op.mere" 2>/dev/null | grep -q 'li a7, 93'; then :; else
  echo "FAIL rv_prelude: a float operator did not lower to the abort"
  rc=1
fi
# The message lives in the binary's data, not in the instruction listing, so
# this looks at the bytes. `grep -a` because the file is binary and grep would
# otherwise say nothing at all rather than no.
printf 'let _ = print_int (float_bits_hi (f_add 1.5 2.5));\n' > "$TMP/op2.mere"
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
if grep -a -q 'is not lowered yet' "$TMP/op2.bin"; then :; else
  echo "FAIL rv_prelude: the shim message lost the phrase host_matrix.sh keys on"
  echo "  (want 'is not lowered yet' — see the \`stub\` branch in that script)"
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

[ "$rc" = 0 ] && echo "ok rv_prelude: all $COUNT names compile for -rv, and the float shims stop at runtime"
exit $rc
