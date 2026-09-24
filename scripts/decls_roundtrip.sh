#!/bin/sh
# `mere --decls <f>` printed back onto <f> must not change what the program does.
#
# This is the acceptance test for forward declarations (`let fn <name>: <type>;`,
# v0.1.483). The feature's whole purpose is cutting a `let rec ... and ...` chain
# that has outgrown one file, and the only realistic way to write the hundreds of
# declarations that needs is `--decls`. So the property that matters is not "the
# output looks like types" but "the output goes back in": prepend it to the file
# it came from, run both, and the output must be identical.
#
# It is here because that property was FALSE in four different ways at once, on a
# feature whose 7 unit tests were green:
#
#   1. --decls printed the PRELUDE's declarations too -- about 70 of them ahead of
#      the program's own -- under post-uniquify names like `decr__v2`.
#   2. --decls RAN the program. `process_decls` evaluates every top-level let, so
#      asking a program for its declarations executed it and interleaved its
#      stdout with them.
#   3. `let fn` could not name a module member. `module M { let f = ... }` renames
#      to `M.f`, the lexer makes `.` its own token, and the parser only matched a
#      single identifier: 625 of the corpus's declarations were unreadable.
#   4. A declaration for a name that shadows a builtin silently moved the shadow
#      up to the declaration, changing which function callers above the definition
#      called. (Now printed commented-out, with the reason.)
#
# None of those is visible from a unit test that writes a three-line program by
# hand. All four are visible in one line of output from this.
set -u
cd "$(dirname "$0")/.." || exit 2
M=./_build/default/bin/mere.exe
[ -x "$M" ] || { echo "decls_roundtrip: $M not built" >&2; exit 2; }
RT=test/parity/__decls_rt.mere
trap 'rm -f "$RT"' EXIT INT TERM
# ⚠ THE EXEMPTION IS GONE (v0.1.530). `module_qualified_record_closure` used a
# record type declared inside a module, which could not be named in an
# annotation from outside it -- `M.t` and `t` were both rejected. Q-125 fixed
# that in v0.1.525, and this script's own rule ("if it starts passing, FAIL")
# is what said so, the first time anybody ran it afterwards. Every program in
# the corpus is checked the same way now.
norm() {  # a diagnostic names the file and the line, and the round-trip file is
          # a different name with the declarations added on top. Neither is a
          # difference in what the program does.
          #
          # `echo` is the same fact from the other side: it PRINTS the line it
          # is written on, and the round-trip file has the declarations above
          # it, so the line it truthfully reports is a different number. A
          # program that names its own positions cannot be invariant under
          # prepending text to it; the position is normalised here exactly like
          # a diagnostic's, and the value it echoes still has to match.
  LC_ALL=C sed -E 's|[^ ]*parity/[A-Za-z_0-9]+\.mere|F|g; s/:[0-9]+:[0-9]+/:L:C/g; s/^ *[0-9]+ \|/N |/; s/^line [0-9]+: /line L: /'
}
ok=0; bad=0; skip=0; failures=''
for f in test/parity/*.mere; do
  case "$f" in *__decls_rt*) continue;; esac
  base=$("$M" "$f" 2>&1 | norm)
  d=$("$M" --decls "$f" 2>/dev/null) || { skip=$((skip+1)); continue; }
  [ -n "$d" ] || { skip=$((skip+1)); continue; }
  { printf '%s\n' "$d"; cat "$f"; } > "$RT"
  out=$("$M" "$RT" 2>&1 | norm)
  b=$(basename "$f" .mere)
  if [ "$base" = "$out" ]; then
    ok=$((ok+1))
  else
    bad=$((bad+1))
    failures="$failures  $b: $(printf '%s' "$out" | LC_ALL=C tr -cd '\11\12\40-\176' | head -1 | cut -c1-90)
"
  fi
done
# A gate whose subject vanished is not a gate that passed.
if [ "$ok" -lt 100 ]; then
  echo "decls_roundtrip: only $ok programs round-tripped and $skip were skipped -- the corpus or the CLI is not what this expects" >&2
  exit 1
fi
if [ "$bad" -gt 0 ]; then
  printf 'decls_roundtrip: %d program(s) behave differently with their own --decls output prepended:\n%s' "$bad" "$failures" >&2
  exit 1
fi
echo "decls_roundtrip: $ok programs round-trip through --decls ($skip skipped, no exemptions)"
