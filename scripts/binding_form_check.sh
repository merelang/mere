#!/bin/sh
# scripts/binding_form_check.sh — the same program gets the same verdict
# however the binding is spelled.
#
# WHAT THIS IS FOR. A top-level binding can be written `let f = ...`,
# `let rec f = ...`, as a member of a `let rec ... and ...` group, or inside a
# `module`. Those are four spellings of one thing, and the compiler walks
# declarations in FOUR places (the interpreter's loop, `type_of`,
# `region_param_report`, `infer_program_inner`). That is sixteen chances for a
# rule to be written in one arm and not the other.
#
# It was. Q-164: every loop routed `let` through `infer_top_let` and
# `top_let_scheme` and inlined `let rec` by hand, so `let rec` had neither
#
#   - the LIBRARY BOUNDARY check. `let store = vec_new ();` plus a function
#     that puts a call-built container into it is refused under `--lib`; the
#     same program spelled `let rec` compiled, and each exported call read back
#     memory the previous call had freed.
#   - the VALUE RESTRICTION. `let store = vec_new ();` is monomorphic; spelled
#     `let rec` it was generalised, and one Vec held an int and a str at once.
#
# WHAT IS CHECKED: for each property, the program is written in every spelling
# and every spelling must return the SAME verdict. A rule that lands in one arm
# is a failure here even when the arm it landed in is right.
#
# Usage:
#   sh scripts/binding_form_check.sh            # check
#   sh scripts/binding_form_check.sh --poison   # check that it can go red
#
# THE POISONS are three:
#   1. a program that must be ACCEPTED in every spelling — a compiler that
#      refused everything would otherwise pass this gate;
#   2. a `mere` that refuses only the `let` spelling (the exact shape of the
#      bug) must make the gate go red;
#   3. a `mere` that refuses everything must fail poison 1.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "binding_form: $MERE not built" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/binding_form.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

# $1 = spelling, $2 = lines that must come BEFORE the binding, $3 = the
# binding's name, $4 = its value, $5 = the rest of the program
spell() {
  [ -z "$2" ] || printf '%s\n' "$2"
  case "$1" in
    let)        printf 'let %s = %s;\n%s\n' "$3" "$4" "$5" ;;
    letrec)     printf 'let rec %s = %s;\n%s\n' "$3" "$4" "$5" ;;
    group)      printf 'let rec %s = %s\nand __sib = fn (q: int) -> q;\n%s\n' "$3" "$4" "$5" ;;
    module)     printf 'module __M {\n  let %s = %s;\n}\n%s\n' "$3" "$4" "$5" ;;
    modulerec)  printf 'module __M {\n  let rec %s = %s;\n}\n%s\n' "$3" "$4" "$5" ;;
  esac
}

FORMS="let letrec group module modulerec"

# $1=label $2=preamble $3=name $4=value $5=rest $6=flags $7=expected $8=needle
property() {
  label=$1; pre=$2; name=$3; value=$4; rest=$5; flags=$6; want=$7; needle=$8
  bad=0
  for form in $FORMS; do
    case "$form" in module|modulerec) qn="__M.$name" ;; *) qn="$name" ;; esac
    spell "$form" "$pre" "$name" "$value" \
      "$(printf '%s' "$rest" | sed "s/@/$qn/g")" > "$tmp/p.mere"
    if [ -z "$flags" ]; then "$MERE" check "$tmp/p.mere" > "$tmp/o" 2>&1
    else "$MERE" $flags "$tmp/p.mere" > "$tmp/o" 2>&1; fi
    rc=$?
    if [ "$want" = refused ]; then
      if [ "$rc" = 0 ] || ! grep -q "$needle" "$tmp/o"; then
        printf '  FAIL  %-22s %s accepted it\n' "$label" "$form"; bad=1
      fi
    else
      if [ "$rc" != 0 ]; then
        printf '  FAIL  %-22s %s refused it (%s)\n' "$label" "$form" "$(head -1 "$tmp/o" | cut -c1-50)"; bad=1
      fi
    fi
  done
  [ "$bad" = 0 ] && printf '  ok    %-22s all %s spellings agree (%s)\n' "$label" "$(printf '%s' "$FORMS" | wc -w | tr -d ' ')" "$want"
  return "$bad"
}

fail=0

# (1) the library boundary: a call-built container put into module state.
property "lib boundary" 'let store = vec_new ();' keep \
  'fn (n: int) -> let v = vec_new () in let _ = vec_push v n in let _ = vec_push store v in vec_len store' \
  'print_int (@ 1)' "--lib -c" refused "region escape across the library boundary" \
  || fail=1

# (2) the value restriction: a container binding must not be generalised.
property "value restriction" '' store 'vec_new ()' \
  'let _ = vec_push @ 1;
let _ = vec_push @ "s";
print_int (vec_len @)' "" refused "expected" || fail=1

# ⚠ POISON 1 lives in the main run, not behind the flag: a gate whose every
# check is "this is refused" passes on a compiler that refuses everything.
property "a sound program" '' twice 'fn (n: int) -> n * 2' 'print_int (@ 21)' \
  "" accepted "" || fail=1

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  # POISON 2: a compiler that refuses ONLY the `let` spelling — the bug's shape.
  cat > "$tmp/only_let" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in *.mere) f="\$a";; esac; done
if head -1 "\$f" | grep -q '^let rec'; then exit 0; fi
if head -2 "\$f" | grep -q '^  let rec'; then exit 0; fi
echo "type error: region escape across the library boundary: \\\`store\\\`" >&2
echo "expected" >&2
exit 1
EOF
  chmod +x "$tmp/only_let"
  if MERE="$tmp/only_let" sh "$0" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "POISON: a compiler that refuses only the \`let\` spelling passed"
    pfail=1
  else
    printf '  ok    %s\n' "POISON: a compiler that refuses only the \`let\` spelling goes red"
  fi
  # POISON 3: a compiler that refuses everything must fail the sound program.
  printf '#!/bin/sh\necho "type error: no" >&2\nexit 1\n' > "$tmp/refuse_all"
  chmod +x "$tmp/refuse_all"
  if MERE="$tmp/refuse_all" sh "$0" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "POISON: a compiler that refuses everything passed"
    pfail=1
  else
    printf '  ok    %s\n' "POISON: a compiler that refuses everything goes red"
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "binding_form --poison: ok (the gate can go red)"
  else
    echo "binding_form --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "binding_form: ok"; else echo "binding_form: FAILED"; fi
exit "$fail"
