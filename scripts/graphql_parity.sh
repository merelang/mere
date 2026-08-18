#!/bin/sh
# scripts/graphql_parity.sh — check contrib/graphql against graphql-js.
#
# THE SHAPE OF THIS GATE, because it is the part worth copying:
#
#     graphql-js:  print(parse(D))                       -> A
#     us:          Gprint.document (Gparse.document D)    -> M
#     graphql-js:  print(parse(M))                       -> B
#     assert A == B
#
# graphql-js's `print` is a function of the AST alone, so A == B holds exactly
# when the two parses produced the same tree. NOTHING HERE TRANSCRIBES AN AST.
#
# That matters. The obvious way to compare two parsers is to serialise both trees
# into a shared format and diff, but the serialiser for the oracle's tree is code
# somebody here writes, and it can hold the same misreading as the parser it is
# checking — a differential gate that shares a bug with its subject reports
# agreement. Sending our output back through the oracle removes that surface:
# the only thing this script knows how to do is run graphql-js and compare two of
# its outputs to each other.
#
# It also means our printer is not held to graphql-js's formatting, only to
# emitting something that parses back the same. That is the property we want; the
# other one would be busywork.
#
# THE CORPUS IS DERIVED, NOT WRITTEN DOWN. It is a cross product: every kind of
# value in every position that admits a value, every selection form, every
# operation shape, and a set of nested type expressions. A hand-written corpus
# covers the cases the author already handles.
#
# IDEMPOTENCE IS CHECKED SEPARATELY: A is fed back in as a document of its own,
# because a printer that loses something on the first pass and is stable
# afterwards would otherwise pass.
#
# Skips (exit 0) when node or the graphql package is absent.
#
# Usage:
#   sh scripts/graphql_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

command -v node >/dev/null 2>&1 || { echo "graphql_parity: node absent, skipping"; exit 0; }
[ -x "$MERE" ] || { echo "graphql_parity: $MERE not found — run 'dune build'" >&2; exit 1; }

# The oracle is a package, and a package has a version. It is looked for in the
# local tree first and then in the global install — the same way socket_parity
# finds jco's WASI adapter — and the version is PRINTED. url_parity learned the
# hard way that an unpinned oracle turns a machine difference into a page of
# phantom failures.
#
# NODE_PATH is deliberately not used: node stopped honouring it for ESM, and
# graphql-js 17 is ESM-first, so a NODE_PATH that looks like it works resolves
# some entry points and not others.
GQL_DIR=""
for cand in "$ROOT/node_modules/graphql" "$(npm root -g 2>/dev/null)/graphql"; do
  [ -f "$cand/package.json" ] && { GQL_DIR=$cand; break; }
done
if [ -z "$GQL_DIR" ]; then
  echo "graphql_parity: the 'graphql' package was not found, skipping"
  echo "                (npm install -g graphql, or npm install graphql in $ROOT)"
  exit 0
fi
GQL_VER=$(node -p "require('$GQL_DIR/package.json').version")
echo "graphql_parity: oracle is graphql-js $GQL_VER (node $(node -v)) at $GQL_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f "$ROOT/examples/.graphql_parity_tmp.mere"' EXIT
mkdir -p "$TMP/in" "$TMP/out"
fail=0

# --- the corpus, derived --------------------------------------------------
python3 - "$TMP/in" <<'PY'
import sys, pathlib
out = pathlib.Path(sys.argv[1])

# every kind of value the grammar admits
values = [
    "$v", "0", "-3", "12345678901234567890123456789",   # int, incl. one no int64 holds
    "1.0", "-1.5e3", "2E+7", "0.0e-0",                   # float, every exponent spelling
    '"s"', '"q\\"q"', '"b\\\\b"', '"n\\nn"', '"u\\u00e9u"', '""',
    "true", "false", "null", "ENUM_VALUE",
    "[]", "[1]", "[1, \"a\", [2], {k: 3}]",
    "{}", "{a: 1}", "{a: 1, b: [2], c: {d: null}}",
]
# every position that admits a value
positions = [
    lambda v: "{ f(a: %s) }" % v,                       # argument
    lambda v: "{ f(a: [%s]) }" % v,                      # inside a list
    lambda v: "{ f(a: {k: %s}) }" % v,                   # inside an object
    lambda v: "{ f @d(a: %s) }" % v,                     # directive argument
]
n = 0
def add(doc):
    global n
    n += 1
    out.joinpath("%04d.graphql" % n).write_text(doc)

for v in values:
    for p in positions:
        # a variable is only legal in an operation that defines one
        add(("query Q($v: Int) " + p(v)) if v == "$v" else p(v))

# every selection form
for sel in ["f", "a: f", "f(x: 1)", "f @d", "f @d @e", "f @d(x: 1)",
            "f { g }", "a: f(x: 1) @d { g h }",
            "...F", "...F @d",
            "... on T { g }", "... on T @d { g }",
            "... { g }", "... @d { g }",
            "f { ... on T { g } ...F h: i }"]:
    add("{ %s }" % sel)

# every operation shape
for op in ["query", "mutation", "subscription"]:
    add("%s { f }" % op)
    add("%s Named { f }" % op)
    add("%s Named @d { f }" % op)
    add("%s Named($x: Int) { f }" % op)
    add("%s Named($x: Int = 1) @d { f }" % op)
add("{ f }")                                             # the shorthand
add("query { f }\nmutation { g }\nfragment F on T { h }") # several definitions

# type expressions, nested
for ty in ["Int", "Int!", "[Int]", "[Int]!", "[Int!]", "[Int!]!",
           "[[Int]]", "[[Int!]!]!", "String", "MyType!"]:
    add("query Q($x: %s) { f(a: $x) }" % ty)

# default values, including the one that is present AND null
for d in ["1", "null", "[1]", "{k: 1}", '"s"', "true", "EN"]:
    add("query Q($x: Int = %s) { f }" % d)

# fragments
add("fragment F on T { a }")
add("fragment F on T @d { a }")
add("query { ...F }\nfragment F on T { a }")

# ignored tokens: commas and comments are whitespace, and must not change the tree
add("{ a, b , c }")
add("{ a\n# comment\nb }")
add("{ f(a: 1, b: 2,) }")

# block strings whose value survives re-parsing (see the printer's refusal)
add('{ f(a: """hello""") }')
add('{ f(a: """\nhello\nworld\n""") }')

print(n)
PY
CORPUS=$(ls "$TMP/in" | wc -l | tr -d ' ')

# --- A = print(parse(D)) for every document ------------------------------
cat > "$TMP/oracle.js" <<'NODE'
const fs = require("fs"), path = require("path");
const { parse, print } = require(process.env.GQL_DIR);
const [inDir, outDir] = process.argv.slice(2);
for (const f of fs.readdirSync(inDir).sort()) {
  const src = fs.readFileSync(path.join(inDir, f), "utf8");
  let r;
  try { r = print(parse(src)); } catch (e) { r = "PARSE-ERROR: " + e.message; }
  fs.writeFileSync(path.join(outDir, f + ".A"), r);
}
NODE
mkdir -p "$TMP/A"
GQL_DIR="$GQL_DIR" node "$TMP/oracle.js" "$TMP/in" "$TMP/A"

# A document the ORACLE cannot parse is a bug in the corpus generator, not a
# result. Fail loudly rather than comparing two error strings and calling it
# agreement.
if grep -l "^PARSE-ERROR" "$TMP/A"/* >/dev/null 2>&1; then
  echo "  FAIL  corpus  the oracle rejected documents this script generated:"
  for f in $(grep -l "^PARSE-ERROR" "$TMP/A"/* | head -5); do
    echo "        $(basename "$f" .A): $(head -c 120 "$f")"
    echo "          input: $(head -c 120 "$TMP/in/$(basename "$f" .A)")"
  done
  echo "graphql_parity: FAILED"
  exit 1
fi

# --- M = our parse + print, written per file so no delimiter can be ambiguous
{
  echo 'import "../contrib/graphql/ast.mere";'
  echo 'import "../contrib/graphql/lexer.mere";'
  echo 'import "../contrib/graphql/parser.mere";'
  echo 'import "../contrib/graphql/printer.mere";'
  echo 'let one = fn (src: str, dst: str) ->'
  echo '  write_file dst (Gprint.document (Gparse.document (read_file src)));'
  for f in $(ls "$TMP/in"); do
    printf 'let _ = one "%s" "%s";\n' "$TMP/in/$f" "$TMP/out/$f.M"
  done
  echo '0'
} > "$ROOT/examples/.graphql_parity_tmp.mere"

( ulimit -t 300; "$MERE" "$ROOT/examples/.graphql_parity_tmp.mere" ) > /dev/null

# --- B = print(parse(M)), then compare A and B ---------------------------
cat > "$TMP/back.js" <<'NODE'
const fs = require("fs"), path = require("path");
const { parse, print } = require(process.env.GQL_DIR);
const [aDir, mDir] = process.argv.slice(2);
let bad = 0, n = 0;
for (const f of fs.readdirSync(aDir).sort()) {
  const base = f.replace(/\.A$/, "");
  const A = fs.readFileSync(path.join(aDir, f), "utf8");
  const mPath = path.join(mDir, base + ".M");
  n++;
  if (!fs.existsSync(mPath)) {
    console.log(`MISSING\t${base}\t(we produced no output)`); bad++; continue;
  }
  const M = fs.readFileSync(mPath, "utf8");
  let B;
  try { B = print(parse(M)); }
  catch (e) { console.log(`UNPARSEABLE\t${base}\t${e.message}\n  ours: ${M}`); bad++; continue; }
  if (A !== B) {
    console.log(`DIFF\t${base}\n  oracle: ${JSON.stringify(A)}\n  ours:   ${JSON.stringify(B)}\n  input:  ${JSON.stringify(fs.readFileSync(path.join(process.env.INDIR, base), "utf8"))}`);
    bad++;
  }
}
console.log(`__TOTAL__ ${n} ${bad}`);
NODE
GQL_DIR="$GQL_DIR" INDIR="$TMP/in" node "$TMP/back.js" "$TMP/A" "$TMP/out" > "$TMP/report.txt" 2>&1
BAD=$(sed -n 's/^__TOTAL__ [0-9]* \([0-9]*\)$/\1/p' "$TMP/report.txt")
TOT=$(sed -n 's/^__TOTAL__ \([0-9]*\) [0-9]*$/\1/p' "$TMP/report.txt")

if [ "$BAD" = 0 ]; then
  echo "  ok    round-trip  $TOT documents: print(parse(ours)) == print(parse(theirs))"
else
  echo "  FAIL  round-trip  $BAD of $TOT documents"
  grep -v '^__TOTAL__' "$TMP/report.txt" | head -40 | sed 's/^/        /'
  fail=1
fi

# --- idempotence: feed the oracle's own output back through us -----------
# A printer that drops something on the first pass and is stable afterwards
# would pass the section above. This section is what notices.
rm -rf "$TMP/in2" "$TMP/out2" "$TMP/A2"; mkdir -p "$TMP/in2" "$TMP/out2" "$TMP/A2"
for f in "$TMP/A"/*; do cp "$f" "$TMP/in2/$(basename "$f" .A)"; done
GQL_DIR="$GQL_DIR" node "$TMP/oracle.js" "$TMP/in2" "$TMP/A2"
{
  echo 'import "../contrib/graphql/ast.mere";'
  echo 'import "../contrib/graphql/lexer.mere";'
  echo 'import "../contrib/graphql/parser.mere";'
  echo 'import "../contrib/graphql/printer.mere";'
  echo 'let one = fn (src: str, dst: str) ->'
  echo '  write_file dst (Gprint.document (Gparse.document (read_file src)));'
  for f in $(ls "$TMP/in2"); do
    printf 'let _ = one "%s" "%s";\n' "$TMP/in2/$f" "$TMP/out2/$f.M"
  done
  echo '0'
} > "$ROOT/examples/.graphql_parity_tmp.mere"
( ulimit -t 300; "$MERE" "$ROOT/examples/.graphql_parity_tmp.mere" ) > /dev/null
GQL_DIR="$GQL_DIR" INDIR="$TMP/in2" node "$TMP/back.js" "$TMP/A2" "$TMP/out2" > "$TMP/report2.txt" 2>&1
BAD2=$(sed -n 's/^__TOTAL__ [0-9]* \([0-9]*\)$/\1/p' "$TMP/report2.txt")
TOT2=$(sed -n 's/^__TOTAL__ \([0-9]*\) [0-9]*$/\1/p' "$TMP/report2.txt")
if [ "$BAD2" = 0 ]; then
  echo "  ok    idempotence  $TOT2 already-printed documents survive a second pass"
else
  echo "  FAIL  idempotence  $BAD2 of $TOT2"
  grep -v '^__TOTAL__' "$TMP/report2.txt" | head -20 | sed 's/^/        /'
  fail=1
fi

# --- the one distinction a round-trip cannot see -------------------------
#
# Found by deliberately breaking the lexer: making it call EVERY number an Int
# did not turn this gate red. The reason is structural, not an oversight in the
# corpus — the printer emits a numeric literal's LEXEME unchanged, so
# `IntValue "1.0"` prints `1.0`, the oracle re-parses that as a FloatValue, and
# the two printed documents agree. The input reached the code; the distinction
# was not observable where the comparison happened.
#
# A round-trip gate is blind to any difference that prints identically. So this
# section asks for the kind directly. It is the ONE place here that transcribes
# something from the oracle's tree, and the shared vocabulary is two words —
# `Int` and `Float` — which is small enough that a shared misreading is not a
# real risk. Everything else stays inside the round-trip.
python3 - "$TMP" <<'PY'
import sys, pathlib
# NOTE: "007" is deliberately absent — GraphQL forbids a leading zero in an
# IntValue, and the oracle rejected it. An invalid lexeme here is a bug in
# this generator, not a finding, so it is removed rather than tolerated.
lexemes = ["0", "1", "-3", "12345678901234567890123456789",
           "1.0", "-1.5e3", "2E+7", "0.0e-0", "1e2", "1.5", "-0.0", "1E-9"]
pathlib.Path(sys.argv[1], "nums.txt").write_text("\n".join(lexemes) + "\n")
PY

cat > "$TMP/kinds.js" <<'NODE'
const fs = require("fs");
const { parse } = require(process.env.GQL_DIR);
const NAME = { IntValue: "Int", FloatValue: "Float" };
for (const lex of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
  if (!lex) continue;
  let v;
  try {
    v = parse(`{ f(a: ${lex}) }`)
      .definitions[0].selectionSet.selections[0].arguments[0].value;
  } catch (e) {
    console.log(`CORPUS-BUG ${lex} is not a legal GraphQL value: ${e.message}`);
    continue;
  }
  console.log(`${NAME[v.kind] || v.kind} ${v.value}`);
}
NODE
GQL_DIR="$GQL_DIR" node "$TMP/kinds.js" "$TMP/nums.txt" > "$TMP/kinds_want.txt"

{
  echo 'import "../contrib/graphql/ast.mere";'
  echo 'import "../contrib/graphql/lexer.mere";'
  echo 'import "../contrib/graphql/parser.mere";'
  echo 'let kind_of = fn (v: gval) ->'
  echo '  match v with'
  echo '  | VInt lex -> "Int " ++ lex'
  echo '  | VFloat lex -> "Float " ++ lex'
  echo '  | _ -> "OTHER";'
  echo 'let first_arg = fn (src: str) ->'
  echo '  match Gparse.document src with'
  echo '  | [OpDef (_, _, _, _, [Field (_, _, [(_, v), ..._], _, _), ..._]), ..._] -> kind_of v'
  echo '  | _ -> "SHAPE-UNEXPECTED";'
  while IFS= read -r lex; do
    [ -z "$lex" ] && continue
    printf 'let _ = print (first_arg "\\{ f(a: %s) }");\n' "$lex"
  done < "$TMP/nums.txt"
  echo '0'
} > "$ROOT/examples/.graphql_parity_tmp.mere"

( ulimit -t 180; "$MERE" "$ROOT/examples/.graphql_parity_tmp.mere" ) | sed '$d' > "$TMP/kinds_ours.txt"

if diff -q "$TMP/kinds_want.txt" "$TMP/kinds_ours.txt" >/dev/null; then
  echo "  ok    numeric kind  $(grep -c . "$TMP/nums.txt") lexemes: Int/Float classified as the oracle does"
else
  echo "  FAIL  numeric kind"
  paste -d'|' "$TMP/nums.txt" "$TMP/kinds_want.txt" "$TMP/kinds_ours.txt" \
    | awk -F'|' '$2 != $3 { printf "        %-32s oracle=%-16s ours=%s\n", $1, $2, $3 }'
  fail=1
fi

[ "$fail" = 0 ] && echo "graphql_parity: ok ($CORPUS generated documents)" \
                || echo "graphql_parity: FAILED"
[ "$fail" = 0 ]
