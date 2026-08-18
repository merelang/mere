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

# THE SUBJECT IS ALLOWED TO CRASH, AND THAT MUST BE REPORTED RATHER THAN FATAL.
#
# `set -e` plus a failing `$MERE` used to abort this script in the middle: the
# raw Mere error printed, no verdict line appeared, and EVERY SECTION AFTER THE
# CRASH WAS SILENTLY SKIPPED. A parser change that made one corpus document
# unparseable therefore hid the reject-list and the numeric-kind sections
# entirely — the same shape as a skip path that hides what it has not reached.
#
# Found by deliberately dropping `repeatable` from the parser: the harness said
# nothing at all and exited as though it had run.
#
# So the subject runs through this, which never aborts, names the section, and
# lets the remaining sections still run.
run_subject() {  # run_subject <label> <mere-file> [<stdout-file>]
  label=$1; file=$2; out=${3:-/dev/null}
  if ( ulimit -t 300; "$MERE" "$file" ) > "$out" 2> "$TMP/subject.err"; then
    return 0
  else
    echo "  FAIL  $label  the parser itself failed on this section:"
    sed 's/^/          /' "$TMP/subject.err" | head -4
    fail=1
    return 1
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f "$ROOT/examples/.graphql_parity_tmp.mere"' EXIT
mkdir -p "$TMP/in" "$TMP/out"
fail=0

# `set -e` was right for the preflight — a missing oracle should stop everything —
# and WRONG for the sections. Every section below records its own verdict in
# `fail`, so an abort here does not add safety, it removes sections: the first
# section whose subject crashed took the rest of the harness with it and the
# script exited having printed no summary. From here on, a failing command is a
# recorded failure, not the end of the run.
set +e

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

# --- type-system definitions (SDL) ---------------------------------------
# Same idea: cross the axes rather than write down the cases somebody thought of.
descs = ["", '"d" ', '"""d""" ']
dirs  = ["", " @d", " @d @e", " @d(x: 1)"]

for desc in descs:
    for d in dirs:
        add(f"{desc}scalar S{d}")
        add(f"{desc}type T{d}")
        add(f"{desc}type T{d} {{ f: Int }}")
        add(f"{desc}interface I{d} {{ a: Int }}")
        add(f"{desc}union U{d} = A")
        add(f"{desc}enum E{d} {{ A }}")
        add(f"{desc}input In{d} {{ a: Int }}")
        add(f"{desc}schema{d} {{ query: Q }}")
        # a directive DEFINITION cannot itself carry directives, so `d` is not
        # applied here — the axis does not exist for this production.
        add(f"{desc}directive @dd on FIELD")

# objects and interfaces: implements × fields
for impl in ["", " implements A", " implements A & B", " implements A & B & C"]:
    for fields in ["", " { f: Int }", " { f: Int g: String! }"]:
        add(f"type T{impl}{fields}")
        add(f"interface I{impl}{fields}")

# field definitions: arguments × types × directives
for args in ["", "(x: Int)", "(x: Int = 1)", "(x: Int, y: [String!]! = [])",
             '("ad" x: Int)', '("""ad""" x: Int = null)']:
    for ty in ["Int", "Int!", "[Int]", "[[Int!]!]!"]:
        add(f"type T {{ f{args}: {ty} }}")
        add(f"type T {{ f{args}: {ty} @d }}")

# unions, enums, inputs at several sizes
for ms in ["A", "A | B", "A | B | C"]:
    add(f"union U = {ms}")
for vs in ["A", "A B", "A B @d", '"d" A B']:
    add(f"enum E {{ {vs} }}")
for fs in ["a: Int", "a: Int = 1", "a: Int b: String = \"s\"", '"d" a: Int = null']:
    add(f"input In {{ {fs} }}")

# directive definitions: repeatable × arguments × locations
for rep in ["", " repeatable"]:
    for args in ["", "(a: Int)", "(a: Int = 1, b: String)"]:
        for locs in ["FIELD", "FIELD | OBJECT",
                     "QUERY | MUTATION | SUBSCRIPTION | FIELD_DEFINITION"]:
            add(f"directive @dd{args}{rep} on {locs}")

# schema definitions
for ops in ["query: Q", "query: Q mutation: M", "query: Q mutation: M subscription: S"]:
    add(f"schema {{ {ops} }}")

# a whole schema, and a document that mixes SDL with executable definitions
add("""
"The root"
type Query { hello(name: String = "world"): String! users: [User!]! }
"A user"
type User implements Node { id: ID! name: String @deprecated(reason: "no") }
interface Node { id: ID! }
union Any = Query | User
enum Colour { RED GREEN "a blue" BLUE @deprecated }
input Filter { name: String limit: Int = 10 }
directive @auth(role: String!) repeatable on FIELD_DEFINITION | OBJECT
schema { query: Query }
""".strip())

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

run_subject "round-trip" "$ROOT/examples/.graphql_parity_tmp.mere" || true

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

run_subject "numeric kind" "$ROOT/examples/.graphql_parity_tmp.mere" "$TMP/kinds_raw.txt" || true
sed '$d' "$TMP/kinds_raw.txt" > "$TMP/kinds_ours.txt" 2>/dev/null || : > "$TMP/kinds_ours.txt"

if diff -q "$TMP/kinds_want.txt" "$TMP/kinds_ours.txt" >/dev/null; then
  echo "  ok    numeric kind  $(grep -c . "$TMP/nums.txt") lexemes: Int/Float classified as the oracle does"
else
  echo "  FAIL  numeric kind"
  paste -d'|' "$TMP/nums.txt" "$TMP/kinds_want.txt" "$TMP/kinds_ours.txt" \
    | awk -F'|' '$2 != $3 { printf "        %-32s oracle=%-16s ours=%s\n", $1, $2, $3 }'
  fail=1
fi

# --- what must be REJECTED -----------------------------------------------
#
# Everything above feeds valid documents. A parser that accepts anything passes
# all of it. So this section is the other half: documents the ORACLE rejects,
# which we must reject too. Each runs in its own process because a refusal aborts.
#
# The distinction being checked is not "does it error" but "does it error INSTEAD
# of quietly producing a tree" — a parser that reads `{ a` as `{ a }` has invented
# a closing brace, and nothing in the round-trip section would notice.
python3 - "$TMP" <<'PY'
import sys, pathlib
bad = [
    "{ a",                       # unterminated selection set
    "{ a }}",                    # a brace too many
    "{ }",                       # a selection set needs a selection
    "{ f(a: ) }",                # an argument needs a value
    "{ f(a 1) }",                # an argument needs a colon
    "query",                     # an operation needs a selection set
    "query Q(",                  # unterminated variable definitions
    "query Q($x) { f }",         # a variable definition needs a type
    "query Q($x: ) { f }",       # ... and the type must be there
    "fragment on T { a }",       # a fragment may not be called `on`
    "fragment F T { a }",        # `on` is not optional
    "fragment F on { a }",       # ... and it needs a type
    "{ ...on }",                 # `on` needs a type condition
    "{ f @ }",                   # a directive needs a name
    "{ f(a: [1) }",              # unterminated list
    "{ f(a: {k: 1) }",           # unterminated object
    "{ f(a: 007) }",             # an IntValue may not have a leading zero
    "{ f(a: .5) }",              # a FloatValue needs an integer part
    "{ f(a: 1.) }",              # ... and a fraction needs a digit
    '{ f(a: "unterminated) }',   # unterminated string
    "type",                      # a type definition needs a name
    "type T { }",                # a fields block may not be empty
    "type T { f }",              # a field definition needs a type
    "union U =",                 # a union needs a member
    "enum E { }",                # an enum values block may not be empty
    "input In { }",              # ... nor an input fields block
    "directive dd on FIELD",     # a directive definition needs `@`
    "directive @dd on",          # ... and at least one location
    "schema { query }",          # an operation type needs a named type
    "!",                         # not a definition
    ". ",                        # a lone dot is not a token
    "schema { }",                # a schema definition needs a root operation type
    "{ f() }",                   # an argument list may not be empty
    "query Q() { f }",           # nor a variable definition list
    "type T { f(): Int }",       # nor an argument DEFINITION list
    "{ f(a: 1.2.3) }",           # a number may not be followed by `.`
    "{ f(a: 1abc) }",            # nor by a name start
]
pathlib.Path(sys.argv[1], "bad.txt").write_text("\n".join(bad) + "\n")
PY

cat > "$TMP/badcheck.js" <<'NODE'
const fs = require("fs");
const { parse } = require(process.env.GQL_DIR);
for (const doc of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
  if (!doc) continue;
  let ok = "REJECT";
  try { parse(doc); ok = "ACCEPT"; } catch (e) {}
  console.log(ok);
}
NODE
GQL_DIR="$GQL_DIR" node "$TMP/badcheck.js" "$TMP/bad.txt" > "$TMP/bad_oracle.txt"

# A document in this list that the ORACLE accepts is a bug in the list, not a
# finding — the same rule as the corpus check above.
if grep -qx ACCEPT "$TMP/bad_oracle.txt"; then
  echo "  FAIL  reject-list  the oracle ACCEPTS documents this list calls invalid:"
  paste -d'|' "$TMP/bad.txt" "$TMP/bad_oracle.txt" \
    | awk -F'|' '$2 == "ACCEPT" { printf "        %s\n", $1 }' | head -8
  fail=1
else
  nbad=0; nwrong=0
  while IFS= read -r doc; do
    [ -z "$doc" ] && continue
    nbad=$((nbad + 1))
    printf 'import "../contrib/graphql/ast.mere";\nimport "../contrib/graphql/lexer.mere";\nimport "../contrib/graphql/parser.mere";\nimport "../contrib/graphql/printer.mere";\nprint (Gprint.document (Gparse.document (read_file "%s")))\n' \
      "$TMP/one.graphql" > "$ROOT/examples/.graphql_parity_tmp.mere"
    printf '%s' "$doc" > "$TMP/one.graphql"
    if ( ulimit -t 60; "$MERE" "$ROOT/examples/.graphql_parity_tmp.mere" ) >/dev/null 2>&1; then
      echo "        ACCEPTED (should have been refused): $doc"
      nwrong=$((nwrong + 1))
    fi
  done < "$TMP/bad.txt"
  if [ "$nwrong" = 0 ]; then
    echo "  ok    reject-list  $nbad documents the oracle rejects are refused here too"
  else
    echo "  FAIL  reject-list  $nwrong of $nbad were accepted"
    fail=1
  fi
fi

# --- the documented gap, checked ----------------------------------------
#
# Type-system EXTENSIONS are valid GraphQL that this parser does not implement.
# That is a gap, and a gap is only honest if it is CHECKED: the parser must refuse
# `extend` rather than read it as the non-extension form, and this asserts the
# refusal. When extensions land, this section fails and says the assertion is
# stale — the same discipline as the DIVERGE pin in proto_parity.
printf 'extend type T { a: Int }' > "$TMP/one.graphql"
printf 'import "../contrib/graphql/ast.mere";\nimport "../contrib/graphql/lexer.mere";\nimport "../contrib/graphql/parser.mere";\nimport "../contrib/graphql/printer.mere";\nprint (Gprint.document (Gparse.document (read_file "%s")))\n' \
  "$TMP/one.graphql" > "$ROOT/examples/.graphql_parity_tmp.mere"
if ( ulimit -t 60; "$MERE" "$ROOT/examples/.graphql_parity_tmp.mere" ) >/dev/null 2>&1; then
  echo "  FAIL  extensions  `extend type T` was ACCEPTED — either extensions now work"
  echo "        (retire this section) or they are being mis-parsed as a plain definition."
  fail=1
else
  echo "  DOCUMENTED-GAP  extensions  \`extend ...\` is refused, not mis-parsed"
fi

[ "$fail" = 0 ] && echo "graphql_parity: ok ($CORPUS generated documents)" \
                || echo "graphql_parity: FAILED"
[ "$fail" = 0 ]
