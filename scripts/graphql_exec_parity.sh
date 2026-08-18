#!/bin/sh
# scripts/graphql_exec_parity.sh — check contrib/graphql/exec.mere against
# graphql-js's execute().
#
# WHY THE RESOLVERS ARE THE DATA. A field here is resolved by looking its name up
# in the parent object, which is what graphql-js does by default. Both sides
# therefore get the same schema, the same document and the same root value, and
# NOTHING ABOUT RESOLUTION IS TRANSCRIBED. Two hand-written resolver sets would
# drift, and the drift would look like an execution difference.
#
# WHAT THIS ACTUALLY EXERCISES, and it is more than field selection: null
# propagation. A non-null field that resolves to null is not an error in that
# field — it destroys the nearest NULLABLE ancestor. `{ nn }` answers
# `"data": null`, and an item error in `[Int!]` nulls the whole list with a path of
# `["ln", 1]`. Every one of those was MEASURED off the oracle before being
# implemented, because reading it off the specification and reading it off a
# running implementation are different activities.
#
# ERROR MESSAGES ARE COMPARED VERBATIM. The specification does not fix the prose,
# so matching the reference implementation is the only way to compare messages at
# all; the oracle's version is pinned and printed. `locations` are STRIPPED from
# both sides — they need source positions the parser does not carry, and that is a
# stated gap, not an accident.
#
# Skips (exit 0) without node or the graphql package.
#
# Usage:
#   sh scripts/graphql_exec_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

command -v node >/dev/null 2>&1 || { echo "graphql_exec_parity: node absent, skipping"; exit 0; }
[ -x "$MERE" ] || { echo "graphql_exec_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
GQL_DIR=""
for cand in "$ROOT/node_modules/graphql" "$(npm root -g 2>/dev/null)/graphql"; do
  [ -f "$cand/package.json" ] && { GQL_DIR=$cand; break; }
done
[ -n "$GQL_DIR" ] || { echo "graphql_exec_parity: 'graphql' not found, skipping"; exit 0; }
echo "graphql_exec_parity: oracle is graphql-js $(node -p "require('$GQL_DIR/package.json').version") (node $(node -v))"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f "$ROOT/examples/.gexec_tmp.mere"' EXIT
fail=0
set +e

run_subject() {
  if ( ulimit -t 240; "$MERE" "$2" ) > "$3" 2> "$TMP/err.txt"; then return 0; fi
  echo "  FAIL  $1  the executor itself failed on this section:"
  sed 's/^/          /' "$TMP/err.txt" | head -6
  fail=1
  return 1
}

# --- the corpus, derived -------------------------------------------------
python3 - "$TMP" <<'PY'
import sys, json, pathlib
tmp = pathlib.Path(sys.argv[1])

SDL = (" type Query { i: Int i2: Int! s: String s2: String! b: Boolean f: Float"
       " e: E e2: E! o: O o2: O! l: [Int] ln: [Int!] l2: [Int]! lo: [O] lon: [O!]"
       " ll: [[Int]] }"
       " type O { x: Int y: String nnx: Int! sub: O }"
       " enum E { RED GREEN }")
FRAGS = " fragment FO on O { x y } fragment FQ on Query { i s } fragment FX on O { nnx }"

cases = []
def add(q, root, variables=None, frags=False):
    cases.append({"q": q + (FRAGS if frags else ""), "root": root,
                  "vars": variables or {}})

# leaves: the right value, a coercible one, and an absent one
for fld, good in [("i", 5), ("s", "str"), ("b", True), ("f", 2.5), ("e", "GREEN")]:
    add("{ %s }" % fld, {fld: good})
    add("{ %s }" % fld, {})
add("{ i }", {"i": "7"})            # a string coerces to Int
add("{ i }", {"i": 1.7})            # ... and a non-integral one does not
add("{ f }", {"f": 3})              # an int widens to Float
add("{ s }", {"s": 42})             # ... and an int stringifies

# --- a variable's own default is applied ---------------------------------
#
# The related rule — AN EXPLICITLY-NULL VARIABLE BEATS ITS DEFAULT — is fixed in the
# executor and is NOT gated here, because it is not observable from this harness:
# `lookup_var` answers null both for "supplied as null" and for "not supplied", and the
# only place a variable is observable without an argument-taking resolver is
# `@skip` / `@include`, whose `if:` is `Boolean!` — so the oracle answers a coercion
# error there rather than a different value, and that error is a gap of its own.
# It is gated in the arguments section instead, where a resolver can echo what it got.
add("query Q($v: Boolean = true) { s @include(if: $v) }", {"s": "x"}, {})
add("query Q($v: Boolean = true) { s @include(if: $v) }", {"s": "x"}, {"v": False})
add("query Q($v: Boolean = false) { s @skip(if: $v) }", {"s": "x"}, {})
add("{ e }", {"e": "BLUE"})         # not a member
add("{ f }", {"f": 1.0})            # an integral float prints without its fraction
add("{ f }", {"f": 100.0})

# non-null leaves, present and absent
for fld in ("i2", "s2", "e2"):
    add("{ %s }" % fld, {fld: {"i2": 1, "s2": "x", "e2": "RED"}[fld]})
    add("{ %s }" % fld, {})

# objects: present, null, absent, nested, and a non-null field inside
add("{ o { x y } }", {"o": {"x": 1, "y": "a"}})
add("{ o { x } }", {"o": None})
add("{ o { x } }", {})
add("{ o { sub { x } } }", {"o": {"sub": {"x": 2}}})
add("{ o { sub { x } } }", {"o": {}})
add("{ o { nnx } }", {"o": {}})                       # bubbles to `o`
add("{ o2 { nnx } }", {"o2": {}})                     # ... and past it, to data
add("{ o2 { x } }", {"o2": None})
add("{ i o { nnx } }", {"i": 9, "o": {}})             # a sibling survives

# lists: nulls inside, non-null items, a non-null list, lists of objects, nesting
add("{ l }", {"l": [1, 2, 3]})
add("{ l }", {"l": []})
add("{ l }", {"l": [1, None, 3]})
add("{ l }", {"l": None})
add("{ ln }", {"ln": [1, 2]})
add("{ ln }", {"ln": [1, None, 3]})                   # path ["ln", 1]
add("{ ln }", {"ln": [None, None]})                   # the FIRST error only? measured
add("{ l2 }", {"l2": None})                           # a non-null list that is null
add("{ lo { x } }", {"lo": [{"x": 1}, None, {"x": 3}]})
add("{ lon { x } }", {"lon": [{"x": 1}, None]})
add("{ lo { nnx } }", {"lo": [{"nnx": 1}, {}]})
add("{ ll }", {"ll": [[1, 2], None, [3]]})

# aliases, repeated fields, __typename at each level
add("{ a1: i a2: i i }", {"i": 4})
add("{ __typename }", {})
add("{ o { __typename x } }", {"o": {"x": 1}})
add("{ __typename o { __typename sub { __typename } } }", {"o": {"sub": {}}})

# fragments: matching, non-matching, inline, nested
add("{ o { ...FO } }", {"o": {"x": 1, "y": "b"}}, frags=True)
add("{ ...FQ }", {"i": 1, "s": "z"}, frags=True)
add("{ o { ... on O { x } } }", {"o": {"x": 5}})
add("{ o { ... on Query { x } } }", {"o": {"x": 5}})   # condition does not match
# The same for a NAMED spread, which is a different arm in the executor. Poisoning
# the named-spread condition check went unnoticed until these existed: the corpus
# had only the inline form, so one of two nearly identical branches was unchecked.
add("{ o { ...FQ } }", {"o": {"i": 1, "s": "q"}}, frags=True)
add("{ ...FO }", {"x": 1, "y": "p"}, frags=True)
add("{ o { x ...FQ } }", {"o": {"x": 3, "i": 9}}, frags=True)
add("{ o { ... { x } } }", {"o": {"x": 6}})            # no condition
add("{ o { ...FX } }", {"o": {}}, frags=True)          # a bubble through a fragment
add("{ o { x ... on O { y } } }", {"o": {"x": 1, "y": "c"}})

# @skip / @include, with literals, with variables, and with a default
add("{ i @skip(if: true) s }", {"i": 1, "s": "k"})
add("{ i @skip(if: false) s }", {"i": 1, "s": "k"})
add("{ i @include(if: false) s }", {"i": 1, "s": "k"})
add("{ i @include(if: true) }", {"i": 1})
add("query Q($v: Boolean!){ i @skip(if: $v) s }", {"i": 1, "s": "k"}, {"v": True})
add("query Q($v: Boolean!){ i @include(if: $v) s }", {"i": 1, "s": "k"}, {"v": False})
add("query Q($v: Boolean = true){ i @include(if: $v) }", {"i": 1})
add("query Q($v: Boolean = false){ i @include(if: $v) s }", {"i": 1, "s": "k"})
add("{ o { x @skip(if: true) y } }", {"o": {"x": 1, "y": "d"}})
add("{ o @skip(if: true) i }", {"o": {}, "i": 2})
add("{ ...FQ @skip(if: true) b }", {"i": 1, "s": "z", "b": False}, frags=True)
add("{ o { ... on O @skip(if: true) { x } y } }", {"o": {"x": 1, "y": "e"}})

for c in cases:
    c["sdl"] = SDL
tmp.joinpath("cases.json").write_text(json.dumps(cases))
print(len(cases))
PY
NCASES=$(node -p "require('$TMP/cases.json').length")

# --- the oracle ----------------------------------------------------------
cat > "$TMP/oracle.js" <<'NODE'
const fs = require("fs");
const { buildSchema, parse, execute } = require(process.env.GQL_DIR);
const cases = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
// `locations` are dropped: they need source positions the Mere parser does not
// carry. Everything else — the message, the path, the data, and the ORDER of all
// of it — is compared as it comes.
const strip = r => {
  const out = {};
  if (r.errors) out.errors = r.errors.map(e => ({ message: e.message, path: e.path }));
  out.data = r.data === undefined ? null : r.data;
  return out;
};
(async () => {
  const lines = [];
  for (const c of cases) {
    try {
      const r = await execute({
        schema: buildSchema(c.sdl), document: parse(c.q),
        rootValue: c.root, variableValues: c.vars,
      });
      lines.push(JSON.stringify(strip(r)));
    } catch (e) { lines.push("ORACLE-ERROR: " + e.message); }
  }
  fs.writeFileSync(process.argv[3], lines.join("\n") + "\n");
})();
NODE
GQL_DIR="$GQL_DIR" node "$TMP/oracle.js" "$TMP/cases.json" "$TMP/want.txt"

if grep -q "^ORACLE-ERROR" "$TMP/want.txt"; then
  echo "  FAIL  corpus  the oracle could not run cases this script generated:"
  grep -n "^ORACLE-ERROR" "$TMP/want.txt" | head -5 | sed 's/^/        /'
  echo "graphql_exec_parity: FAILED"; exit 1
fi

# --- the subject ---------------------------------------------------------
# The root value is emitted as a Mere `gvalue` literal, from the same JSON the
# oracle was handed — so the two sides cannot be given different data.
CASES="$TMP/cases.json" node > "$ROOT/examples/.gexec_tmp.mere" <<'NODE'
const fs = require("fs");
const cases = JSON.parse(fs.readFileSync(process.env.CASES, "utf8"));
const esc = s => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\{/g, "\\{")
                  .replace(/\n/g, "\\n");
const lit = v => {
  if (v === null) return "GNull";
  if (typeof v === "boolean") return `GBool ${v}`;
  if (typeof v === "number")
    return Number.isInteger(v) ? `GInt ${v}` : `GFloat ${v}`;
  if (typeof v === "string") return `GStr "${esc(v)}"`;
  if (Array.isArray(v)) return `GList ${list(v.map(lit))}`;
  return `GObj ${list(Object.entries(v).map(([k, x]) => `("${esc(k)}", ${lit(x)})`))}`;
};
// `Cons` / `Nil` rather than a list literal: a bracket literal of tuples nests
// badly inside a constructor application, and this is generated code.
const list = xs => xs.reduceRight((acc, x) => `(Cons (${x}, ${acc}))`, "Nil");
const out = ['import "../contrib/graphql/exec.mere";'];
// An integral float has to stay a float: JSON's `1.0` arrives as the number 1, and
// emitting `GInt 1` for a Float field would test the wrong thing. The schema says
// which fields are floats, so the few float cases are marked in the corpus instead
// of guessed here.
for (const c of cases) {
  const vars = list(Object.entries(c.vars).map(([k, v]) => `("${esc(k)}", ${lit(v)})`));
  out.push(`let _ = print (Gexec.run_json (Gparse.document "${esc(c.q + " " + c.sdl)}") (${lit(c.root)}) ${vars});`);
}
out.push("0");
console.log(out.join("\n"));
NODE

if run_subject "execute" "$ROOT/examples/.gexec_tmp.mere" "$TMP/got_raw.txt"; then
  sed '$d' "$TMP/got_raw.txt" > "$TMP/got.txt"
  if diff -q "$TMP/want.txt" "$TMP/got.txt" >/dev/null; then
    echo "  ok    execute  $NCASES cases: data, errors, paths and field order all agree"
  else
    echo "  FAIL  execute"
    node -e '
      const fs = require("fs");
      const w = fs.readFileSync(process.argv[1], "utf8").split("\n");
      const g = fs.readFileSync(process.argv[2], "utf8").split("\n");
      const cs = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
      let n = 0;
      for (let i = 0; i < Math.max(w.length, g.length); i++) {
        if ((w[i] || "") === (g[i] || "")) continue;
        if (++n > 8) break;
        const c = cs[i] || {};
        console.log("        case " + i + ": " + (c.q || "?").slice(0, 60));
        console.log("          root:   " + JSON.stringify(c.root));
        console.log("          oracle: " + (w[i] || "(none)"));
        console.log("          ours:   " + (g[i] || "(none)"));
      }
    ' "$TMP/want.txt" "$TMP/got.txt" "$TMP/cases.json"
    fail=1
  fi
fi

# --- the arguments a resolver receives -----------------------------------
#
# Everywhere above, the resolvers ARE the data — which is what makes the comparison
# mean something: with the default resolver on both sides nothing about resolution is
# transcribed. A field like `user(id: 5)` cannot be data, so a field's value may be a
# function of its coerced arguments instead.
#
# THAT CHANGES WHAT THE ORACLE IS GOOD FOR. A hand-written resolver now exists on both
# sides and the two could drift, so the resolvers here do the one thing that cannot:
# ECHO THE ARGUMENTS THEY RECEIVED, as JSON. The comparison is then about argument
# COERCION — defaults, absence, variables, order — which is exactly where the rules are
# and exactly what nobody can hold in their head:
#
#   * a schema default applies when the argument is omitted
#   * a default of `null` applies too, which is how it differs from having no default
#   * an argument with no default that is not supplied is ABSENT, not null
#   * an explicit `null` is present and null
#   * a variable that was NOT supplied means the argument was not written, so the schema
#     default applies to it
#   * an explicitly-null variable BEATS its own default
#   * the key order is the FIELD DEFINITION's argument order, not the document's
ASDL=' type Query { f(a: Int, b: Int = 7, c: String, d: [Int!], e: Boolean = null): String'
ASDL="$ASDL"' g(x: Int!): String h: String }'
cat > "$TMP/args.txt" <<'CASES'
{ f }	{}
{ f(a: 1) }	{}
{ f(a: 1, b: 2) }	{}
{ f(a: null) }	{}
{ f(b: null) }	{}
{ f(c: "s", d: [1,2]) }	{}
{ f(d: []) }	{}
{ f(e: true) }	{}
query Q($v: Int) { f(a: $v) }	{}
query Q($v: Int) { f(a: $v) }	{"v":5}
query Q($v: Int) { f(a: $v) }	{"v":null}
query Q($v: Int) { f(a: $v, b: $v) }	{}
query Q($v: Int) { f(a: $v, b: $v) }	{"v":3}
query Q($v: Int = 9) { f(a: $v) }	{}
query Q($v: Int = 9) { f(a: $v) }	{"v":null}
query Q($v: Int = 9) { f(b: $v) }	{"v":null}
query Q($v: [Int!]) { f(d: $v) }	{"v":[7,8]}
{ g(x: 1) }	{}
{ h }	{}
CASES
NARGS=$(grep -c . "$TMP/args.txt")

node > "$TMP/args_want.txt" 2>"$TMP/args_oracle.err" <<NODE
import * as g from "$GQL_DIR/index.js";
import { readFileSync } from "fs";
const sdl = '$ASDL';
const schema = g.buildSchema(sdl);
// Every field echoes what it received. \`h\` takes no arguments, so it echoes {} — the
// case that says an argument-free field still goes through the same path.
const root = { f: a => JSON.stringify(a), g: a => JSON.stringify(a),
               h: a => JSON.stringify(a) };
const lines = readFileSync("$TMP/args.txt", "utf8").split("\n").filter(l => l.trim());
const out = [];
for (const line of lines) {
  const [q, v] = line.split("\t");
  const r = g.executeSync({ schema, document: g.parse(q), rootValue: root,
                            variableValues: JSON.parse(v) });
  // The whole response, not just \`data\` — the subject prints \`Gexec.run_json\`, which
  // is the response. Comparing \`r.data\` against a response was the first version and
  // reported every case as differing while every value in them agreed.
  out.push(r.errors ? "ORACLE-ERROR " + r.errors.map(e => e.message).join("; ")
                    : JSON.stringify({ data: r.data }));
}
console.log(out.join("\n"));
NODE
if [ ! -s "$TMP/args_want.txt" ]; then
  echo "  FAIL  arguments  the oracle could not answer:"
  sed 's/^/        /' "$TMP/args_oracle.err" | head -5
  fail=1
elif grep -q "^ORACLE-ERROR" "$TMP/args_want.txt"; then
  echo "  FAIL  arguments  the ORACLE rejected a case this harness wrote:"
  grep -n "^ORACLE-ERROR" "$TMP/args_want.txt" | head -4 | sed 's/^/        /'
  fail=1
else
  {
    echo 'import "../contrib/graphql/exec.mere";'
    printf 'let sdl = "%s";\n' "$(printf '%s' "$ASDL" | sed 's/\\/\\\\/g; s/"/\\"/g; s/{/\\{/g')"
    echo 'let echo = GFn (fn (a) -> GStr (Gexec.to_json (GObj a)));'
    echo 'let root = GObj ([("f", echo), ("g", echo), ("h", echo)]);'
    while IFS="$(printf '\t')" read -r q v; do
      [ -z "$q" ] && continue
      qe=$(printf '%s' "$q" | sed 's/\\/\\\\/g; s/"/\\"/g; s/{/\\{/g')
      ve=$(printf '%s' "$v" | node -e '
        const j = JSON.parse(require("fs").readFileSync(0, "utf8"));
        const lit = v => v === null ? "GNull"
          : typeof v === "boolean" ? `GBool ${v}`
          : typeof v === "number" ? (Number.isInteger(v) ? `GInt ${v}` : `GFloat ${v}`)
          : typeof v === "string" ? `GStr "${v}"`
          : Array.isArray(v) ? `GList ${lst(v.map(lit))}` : "GNull";
        const lst = xs => xs.reduceRight((a, x) => `(Cons (${x}, ${a}))`, "Nil");
        process.stdout.write(lst(Object.entries(j).map(([k, x]) => `("${k}", ${lit(x)})`)));')
      printf 'let _ = print (Gexec.run_json (Gparse.document ("%s" ++ sdl)) root %s);\n' "$qe" "$ve"
    done < "$TMP/args.txt"
    echo '0'
  } > "$ROOT/examples/.gexec_tmp.mere"
  if run_subject "arguments" "$ROOT/examples/.gexec_tmp.mere" "$TMP/args_raw.txt"; then
    sed '$d' "$TMP/args_raw.txt" > "$TMP/args_got.txt"
    if diff -q "$TMP/args_want.txt" "$TMP/args_got.txt" >/dev/null; then
      echo "  ok    arguments  $NARGS cases: defaults, absence, variables and order agree"
    else
      echo "  FAIL  arguments"
      paste -d'|' "$TMP/args.txt" "$TMP/args_want.txt" "$TMP/args_got.txt" \
        | awk -F'|' '$2 != $3 { printf "        %-40s\n          oracle=%.80s\n          ours  =%.80s\n", $1, $2, $3 }' \
        | head -15
      fail=1
    fi
  fi
fi

[ "$fail" = 0 ] && echo "graphql_exec_parity: ok" || echo "graphql_exec_parity: FAILED"
[ "$fail" = 0 ]
