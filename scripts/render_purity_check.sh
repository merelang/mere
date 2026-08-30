#!/bin/sh
# scripts/render_purity_check.sh -- what the render path can reach.
#
# G-1 (render_agreement) compares a server-side walk against a client DOM and
# calls a difference a bug. That only means something if rendering is a
# function of its input. It is not, by construction: `time` and `random_int`
# are unconditional builtins, and a function that reads the clock has the type
# `str -> str` like any other. The language does not seal them.
#
# So this asks what the render path CAN REACH, and asks the compiler rather
# than the source text.
#
# WHAT IS ACTUALLY BOUNDED, having measured it instead of assuming it. The
# first version of this gate claimed to bound what the render path can REACH,
# on the theory that dead code is eliminated. That holds for an unused function
# in the main file -- a program whose only clock call sat in one produced zero
# occurrences of __lang_time -- and does NOT hold across an import: an uncalled
# function reading the clock, added to contrib/html/build.mere, put a
# __lang_time call site into the driver's C.
#
# So the property is coarser than "render cannot reach the clock" and stronger
# than it in a different direction: THE VIEW MODULES CONTAIN NO AMBIENT USE
# ANYWHERE IN THEM. Every function in them, called or not.
#
# Which modules is therefore a list, and a list can be short one entry. Each is
# anchored below by a symbol that must appear in the emitted C, so a module
# that stopped being pulled in is a failure rather than a silent gap.
#
# THE PRELUDE BASELINE IS MEASURED, NOT WRITTEN DOWN. `getenv` appears once in
# any program (a MERE_REGION_STATS diagnostic), and hardcoding "expect 1" would
# rot the day the prelude changes. A trivial program is compiled here and its
# counts are the baseline; the driver must match it exactly.
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
DRIVER=test/render/render_driver.mere
[ -x "$MERE" ] || { echo "render_purity: no compiler at $MERE (run dune build)"; exit 1; }
[ -f "$DRIVER" ] || { echo "render_purity: FAIL -- no driver at $DRIVER"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# Ambient: not a function of the argument. The environment ones are here and
# not only the clock, because G-1's two sides are a SERVER and a BROWSER --
# they do not share an environment, an argv, a filesystem or a stdin, so a
# render that reads any of them differs between the two by construction.
SYMS="__lang_time __lang_random_int __lang_random_float __lang_args __lang_read_file __lang_read_stdin __lang_run getenv"

printf 'print "baseline"\n' > "$tmp/base.mere"
"$MERE" -c "$tmp/base.mere" > "$tmp/base.c" 2>"$tmp/base.err" || {
  echo "render_purity: FAIL -- the baseline program did not compile"; sed -n '1,5p' "$tmp/base.err"; exit 1; }
"$MERE" -c "$DRIVER" > "$tmp/drv.c" 2>"$tmp/drv.err" || {
  echo "render_purity: FAIL -- $DRIVER did not compile"; sed -n '1,10p' "$tmp/drv.err"; exit 1; }

# calls = occurrences - definitions. A definition is `static <type> sym(`;
# subtracting it is what stops the prelude's own body counting as a use.
calls() {  # $1 = file, $2 = symbol
  _t=$(grep -c "$2" "$1" 2>/dev/null || true); _t=${_t:-0}
  _d=$(grep -cE "^static [^(]*${2}[[:space:]]*\(" "$1" 2>/dev/null || true); _d=${_d:-0}
  echo $((_t - _d))
}

fail=0; checked=0
for sym in $SYMS; do
  b=$(calls "$tmp/base.c" "$sym")
  d=$(calls "$tmp/drv.c" "$sym")
  checked=$((checked + 1))
  if [ "$d" -ne "$b" ]; then
    echo "render_purity: FAIL -- a view module uses $sym"
    echo "    $d call site(s) in the driver, $b in a program that only prints."
    echo "    A view that reads it is not a function of its input, and G-1"
    echo "    compares a server against a browser -- two different environments."
    fail=1
  fi
done

# EACH MODULE MUST BE IN THERE. A driver that stopped importing one would pass
# every count above by not containing it -- the emptiest possible way to be
# ambient-free. The anchors are symbols the module defines.
# contrib/html/build imports contrib/http/escape, and contrib/http/csrf_field
# imports build, so dropping one import from the driver may leave the module in
# anyway. csrf_field is the leaf nothing else pulls in -- it is the one whose
# absence this actually catches, which is why the list is anchored per module
# rather than trusted to the driver's import lines.
for anchor in mu_render mu_page_with mu_xml_escape mu_json_escape mu_csrf_hidden_field; do
  grep -q "$anchor" "$tmp/drv.c" || {
    echo "render_purity: FAIL -- $anchor is not in the emitted C, so the module"
    echo "  defining it was not compiled into this program and the counts above"
    echo "  say nothing about it."
    exit 1
  }
done

[ $fail -eq 0 ] || exit 1
echo "render_purity: $checked ambient builtins, no use of any of them anywhere in the view modules (call sites equal a print-only program's)"
