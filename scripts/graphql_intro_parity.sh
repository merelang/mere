#!/bin/sh
# scripts/graphql_intro_parity.sh — introspection, against graphql-js.
#
# The introspection schema is NORMATIVE: the specification fixes every field name,
# type and nullability in `__Schema` / `__Type` / `__Field` / `__InputValue` /
# `__EnumValue` / `__Directive` and the two enums. So there are two different things
# to check and they need different oracles:
#
#   1. THE SCHEMA ITSELF is generated from graphql-js and committed. This harness
#      regenerates it and diffs — the same arrangement as the HPACK tables, because a
#      generator whose output nobody reads is a generator nobody can review.
#   2. THE ANSWERS are compared against graphql-js executing the SAME standard
#      introspection query, the one `getIntrospectionQuery()` produces — 109 lines
#      that nobody here wrote, including `ofType` nested nine deep.
#
# AND THE STRONGEST CHECK IS NEITHER OF THOSE. Feeding our introspection result to
# graphql-js's own `buildClientSchema` and printing it must give back the schema
# `printSchema(buildSchema(sdl))` prints. That is a round trip through the oracle:
# it holds exactly when our answer carries the whole schema, it is blind to field
# ORDER (which the specification does not fix), and NOTHING TRANSCRIBES AN
# INTROSPECTION RESULT — the same reason the document gate compares printed
# documents rather than serialised ASTs.
#
# Skips (exit 0) without node or graphql-js.
#
# Usage:
#   sh scripts/graphql_intro_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

[ -x "$MERE" ] || { echo "graphql_intro_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "graphql_intro_parity: node absent, skipping"; exit 0; }

GQL_DIR=""
for cand in "$ROOT/node_modules/graphql" "$(npm root -g 2>/dev/null)/graphql"; do
  [ -f "$cand/package.json" ] && { GQL_DIR=$cand; break; }
done
if [ -z "$GQL_DIR" ]; then
  echo "graphql_intro_parity: the 'graphql' package was not found, skipping"
  exit 0
fi
GQL_VER=$(node -p "require('$GQL_DIR/package.json').version")
echo "graphql_intro_parity: oracle is graphql-js $GQL_VER (node $(node -v))"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$ROOT/examples/.gintro_tmp.mere"' EXIT
fail=0
set +e

# The subject may crash, and that has to be REPORTED rather than abort the script:
# `set -e` plus a failing $MERE used to end a harness in the middle with no verdict
# line and every later section silently skipped.
run_subject() {
  ( ulimit -t 300; "$MERE" "$2" ) > "$3" 2> "$TMP/err.txt" && return 0
  echo "  FAIL  $1  the subject itself failed:"
  sed 's/^/          /' "$TMP/err.txt" | head -5
  fail=1
  return 1
}

# --- 1. the generated schema is what is committed ------------------------
if sh "$ROOT/scripts/gen_introspection_sdl.sh" > "$TMP/fresh.mere" 2>"$TMP/gen.err"; then
  if diff -q "$TMP/fresh.mere" "$ROOT/contrib/graphql/introspection_sdl.mere" >/dev/null; then
    echo "  ok    generated  introspection_sdl.mere matches a fresh run"
  else
    echo "  FAIL  generated  introspection_sdl.mere is stale — regenerate and commit"
    diff "$ROOT/contrib/graphql/introspection_sdl.mere" "$TMP/fresh.mere" \
      | sed 's/^/        /' | head -8
    fail=1
  fi
else
  echo "  FAIL  generated  the generator failed:"
  sed 's/^/        /' "$TMP/gen.err" | head -4
  fail=1
fi

# --- the corpus ----------------------------------------------------------
#
# Every kind `__TypeKind` names, plus the shapes whose introspection differs from
# their execution: an interface (`possibleTypes` is the implementors, which are found
# by SEARCHING the other definitions rather than listed anywhere), a union (which
# lists them), `@deprecated` with and without a reason, an input field with and
# without a default, and a schema with an explicit `schema { }` block naming
# non-conventional root types.
mkdir -p "$TMP/schemas"
cat > "$TMP/schemas/01_scalars.graphql" <<'S'
type Query { a: Int b: Float c: String d: Boolean e: ID }
S
cat > "$TMP/schemas/02_wrappers.graphql" <<'S'
type Query { a: [Int] b: [Int!] c: [Int]! d: [Int!]! e: [[Int!]!]! }
S
cat > "$TMP/schemas/03_enum.graphql" <<'S'
type Query { c: Colour }
enum Colour { RED GREEN BLUE }
S
cat > "$TMP/schemas/04_input.graphql" <<'S'
type Query { a(inp: In): Int }
input In { x: Int = 3 y: String z: [Int!]! = [1, 2] w: Boolean = null }
S
cat > "$TMP/schemas/05_interface.graphql" <<'S'
type Query { n: Node }
interface Node { id: ID! }
type Post implements Node { id: ID! title: String }
type User implements Node { id: ID! name: String }
S
cat > "$TMP/schemas/06_union.graphql" <<'S'
type Query { t: Thing }
type Post { title: String }
type User { name: String }
union Thing = Post | User
S
cat > "$TMP/schemas/07_deprecated.graphql" <<'S'
type Query { a: Int @deprecated b: Int @deprecated(reason: "use a") c: Colour }
enum Colour { RED GREEN @deprecated BLUE @deprecated(reason: "gone") }
S
cat > "$TMP/schemas/08_roots.graphql" <<'S'
schema { query: Q mutation: M }
type Q { a: Int }
type M { b: Int }
S
cat > "$TMP/schemas/09_scalar.graphql" <<'S'
type Query { d: DateTime }
scalar DateTime
S
cat > "$TMP/schemas/10_args.graphql" <<'S'
type Query { a(x: Int, y: String = "s", z: [Int!] = []): Int }
S
cat > "$TMP/schemas/11_nested.graphql" <<'S'
type Query { p: Post }
type Post { author: User comments: [Comment!]! }
type User { name: String posts: [Post!] }
type Comment { body: String author: User }
S
NSCHEMA=$(ls "$TMP/schemas" | wc -l | tr -d ' ')

# --- the oracle's side, once per schema ---------------------------------
node --input-type=module -e "
import * as g from '$GQL_DIR/index.js';
import { readFileSync, writeFileSync, readdirSync } from 'fs';

// \`description\` is dropped from BOTH sides. graphql-js carries prose for the
// built-in scalars and for every introspection type; this executor answers null.
// That is a stated gap, and section 4 asserts our side really is null everywhere —
// so the gap is visible rather than hidden by this normalisation.
function strip(v) {
  if (Array.isArray(v)) return v.map(strip);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v)) { if (k !== 'description') o[k] = strip(v[k]); }
    return o;
  }
  return v;
}
// \`types\` order is not fixed by the specification, so it is sorted by name on both
// sides. Everything else keeps the order it came in — a GraphQL response's field
// order follows the query.
function norm(intro) {
  const s = strip(intro).__schema;
  s.types = s.types.slice().sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  s.directives = s.directives.slice().sort((a, b) => a.name < b.name ? -1 : 1);
  return { __schema: s };
}

const q = g.getIntrospectionQuery();
writeFileSync('$TMP/query.graphql', q);
const out = {};
for (const f of readdirSync('$TMP/schemas').sort()) {
  const sdl = readFileSync('$TMP/schemas/' + f, 'utf8');
  const schema = g.buildSchema(sdl);
  const r = g.executeSync({ schema, document: g.parse(q) });
  if (r.errors) { out[f] = { HARNESS_BUG: r.errors.map(e => e.message) }; continue; }
  out[f] = { intro: norm(r.data), printed: g.printSchema(schema) };
}
writeFileSync('$TMP/oracle.json', JSON.stringify(out, null, 1));
" 2>"$TMP/oracle.err"
if [ ! -f "$TMP/oracle.json" ]; then
  echo "  FAIL  oracle  graphql-js could not answer:"
  sed 's/^/        /' "$TMP/oracle.err" | head -6
  echo "graphql_intro_parity: FAILED"; exit 1
fi
if grep -q HARNESS_BUG "$TMP/oracle.json"; then
  echo "  FAIL  corpus  the ORACLE rejected a schema this harness wrote:"
  node -p "
    const o=require('$TMP/oracle.json');
    Object.entries(o).filter(([,v])=>v.HARNESS_BUG).map(([k,v])=>'        '+k+': '+v.HARNESS_BUG.join('; ')).join('\n')"
  echo "graphql_intro_parity: FAILED"; exit 1
fi
echo "  ok    corpus  $NSCHEMA schemas, all accepted by graphql-js"

# --- 2. the same query, answered here -----------------------------------
#
# The query is the ORACLE'S OWN, read from the file it wrote. Retyping 109 lines
# would be a transcription of the thing being tested.
python3 - "$TMP" <<'PY'
import sys, pathlib, json
tmp = pathlib.Path(sys.argv[1])
q = tmp.joinpath("query.graphql").read_text()

def esc(t):
    return (t.replace("\\", "\\\\").replace('"', '\\"')
             .replace("{", "\\{").replace("\n", "\\n"))

lines = ['import "../contrib/graphql/exec.mere";']
lines.append('let q = "%s";' % esc(q))
for f in sorted(p.name for p in tmp.joinpath("schemas").iterdir()):
    sdl = tmp.joinpath("schemas", f).read_text()
    lines.append('let _ = print (Gexec.run_json (Gparse.document (q ++ "%s")) (GObj ([])) []);'
                 % esc(sdl))
lines.append("0")
tmp.joinpath("subject.mere").write_text("\n".join(lines) + "\n")
PY
cp "$TMP/subject.mere" "$ROOT/examples/.gintro_tmp.mere"
if run_subject "introspection" "$ROOT/examples/.gintro_tmp.mere" "$TMP/ours_raw.txt"; then
  sed '$d' "$TMP/ours_raw.txt" > "$TMP/ours.txt"
  node --input-type=module -e "
import * as g from '$GQL_DIR/index.js';
import { readFileSync, writeFileSync, readdirSync } from 'fs';
const oracle = JSON.parse(readFileSync('$TMP/oracle.json','utf8'));
const files = readdirSync('$TMP/schemas').sort();
const ours = readFileSync('$TMP/ours.txt','utf8').split('\n').filter(l => l.length);

function strip(v) {
  if (Array.isArray(v)) return v.map(strip);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v)) { if (k !== 'description') o[k] = strip(v[k]); }
    return o;
  }
  return v;
}
function norm(intro) {
  const s = strip(intro).__schema;
  s.types = s.types.slice().sort((a,b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  s.directives = s.directives.slice().sort((a,b) => a.name < b.name ? -1 : 1);
  return { __schema: s };
}

let bad = 0, rt = 0, badrt = 0;
const report = [];
files.forEach((f, i) => {
  let mine;
  try { mine = JSON.parse(ours[i]); }
  catch (e) { report.push('        ' + f + ': our output is not JSON: ' + String(ours[i]).slice(0,120)); bad++; return; }
  if (mine.errors) {
    report.push('        ' + f + ': we reported errors: ' + JSON.stringify(mine.errors).slice(0,200));
    bad++; return;
  }
  const a = JSON.stringify(norm(oracle[f].intro), null, 1);
  const b = JSON.stringify(norm(mine.data), null, 1);
  if (a !== b) {
    bad++;
    const al = a.split('\n'), bl = b.split('\n');
    for (let k = 0; k < Math.max(al.length, bl.length); k++) {
      if (al[k] !== bl[k]) {
        report.push('        ' + f + ' first differs at line ' + (k+1));
        report.push('          oracle: ' + String(al[k]).trim().slice(0,110));
        report.push('          ours  : ' + String(bl[k]).trim().slice(0,110));
        break;
      }
    }
  }
  // THE ROUND TRIP. Our introspection result, fed to the oracle's own
  // buildClientSchema and printed, must equal the oracle's printSchema.
  try {
    const client = g.buildClientSchema(mine.data);
    const printed = g.printSchema(client);
    if (printed.trim() !== oracle[f].printed.trim()) {
      badrt++;
      const al = oracle[f].printed.trim().split('\n'), bl = printed.trim().split('\n');
      for (let k = 0; k < Math.max(al.length, bl.length); k++) {
        if (al[k] !== bl[k]) {
          report.push('        ' + f + ' round-trip differs at line ' + (k+1));
          report.push('          oracle: ' + String(al[k]));
          report.push('          ours  : ' + String(bl[k]));
          break;
        }
      }
    } else rt++;
  } catch (e) {
    badrt++;
    report.push('        ' + f + ' buildClientSchema refused our result: ' + e.message.slice(0,160));
  }
});
writeFileSync('$TMP/verdict.txt',
  JSON.stringify({ bad, rt, badrt, n: files.length, report }));
" 2>"$TMP/cmp.err"
  if [ -f "$TMP/verdict.txt" ]; then
    BAD=$(node -p "JSON.parse(require('fs').readFileSync('$TMP/verdict.txt','utf8')).bad")
    RT=$(node -p "JSON.parse(require('fs').readFileSync('$TMP/verdict.txt','utf8')).rt")
    BADRT=$(node -p "JSON.parse(require('fs').readFileSync('$TMP/verdict.txt','utf8')).badrt")
    if [ "$BAD" = 0 ]; then
      echo "  ok    introspection  $NSCHEMA schemas: the standard query answers identically"
    else
      echo "  FAIL  introspection  $BAD of $NSCHEMA"
      node -p "JSON.parse(require('fs').readFileSync('$TMP/verdict.txt','utf8')).report.join('\n')" | head -20
      fail=1
    fi
    if [ "$BADRT" = 0 ]; then
      echo "  ok    round trip  $RT schemas: buildClientSchema(ours) prints the original"
    else
      echo "  FAIL  round trip  $BADRT of $NSCHEMA"
      node -p "JSON.parse(require('fs').readFileSync('$TMP/verdict.txt','utf8')).report.join('\n')" | head -20
      fail=1
    fi
  else
    echo "  FAIL  compare  the comparison itself failed:"
    sed 's/^/        /' "$TMP/cmp.err" | head -6
    fail=1
  fi
fi

# --- 3. __type(name:) ----------------------------------------------------
#
# The other introspection entry point, and the one field in this executor whose
# ARGUMENTS are read — everywhere else arguments are ignored, matching graphql-js's
# default resolver, but `__type` without its argument is a different question.
#
# The cases that are not just "a type by name": an UNKNOWN name answers null and is
# not an error, and an INTROSPECTION type is introspectable like any other, so
# `__type(name: "__Type")` describes the machinery itself.
cat > "$TMP/type_queries.txt" <<'Q'
{ __type(name: "Query") { kind name fields { name type { kind name ofType { kind name } } } } }
{ __type(name: "Colour") { kind name enumValues { name isDeprecated deprecationReason } } }
{ __type(name: "Int") { kind name ofType { name } } }
{ __type(name: "NoSuchType") { kind name } }
{ __type(name: "__Type") { kind name fields { name } } }
{ __type(name: "__TypeKind") { kind name enumValues { name } } }
{ t: __type(name: "Query") { name } u: __type(name: "Colour") { name } }
Q
NTQ=$(grep -c . "$TMP/type_queries.txt")
cat > "$TMP/tq_schema.graphql" <<'S'
type Query { a: Int c: Colour l: [String!]! }
enum Colour { RED GREEN @deprecated(reason: "gone") }
S
node --input-type=module -e "
import * as g from '$GQL_DIR/index.js';
import { readFileSync, writeFileSync } from 'fs';
const sdl = readFileSync('$TMP/tq_schema.graphql','utf8');
const schema = g.buildSchema(sdl);
const out = readFileSync('$TMP/type_queries.txt','utf8').split('\n').filter(l=>l.length)
  .map(q => {
    const r = g.executeSync({ schema, document: g.parse(q) });
    if (r.errors) return 'ORACLE-ERROR ' + r.errors.map(e=>e.message).join('; ');
    // \`description\` is dropped on both sides — see section 4.
    const strip = v => Array.isArray(v) ? v.map(strip)
      : (v && typeof v === 'object'
          ? Object.fromEntries(Object.entries(v).filter(([k])=>k!=='description').map(([k,x])=>[k,strip(x)]))
          : v);
    return JSON.stringify({ data: strip(r.data) });
  });
writeFileSync('$TMP/tq_want.txt', out.join('\n') + '\n');
" 2>"$TMP/tq.err"
if [ ! -s "$TMP/tq_want.txt" ]; then
  echo "  FAIL  __type  the oracle could not answer:"
  sed 's/^/        /' "$TMP/tq.err" | head -4
  fail=1
elif grep -q ORACLE-ERROR "$TMP/tq_want.txt"; then
  echo "  FAIL  __type  the ORACLE rejected a query this harness wrote:"
  grep ORACLE-ERROR "$TMP/tq_want.txt" | sed 's/^/        /' | head -3
  fail=1
else
  python3 - "$TMP" <<'PY'
import sys, pathlib
tmp = pathlib.Path(sys.argv[1])
def esc(t):
    return (t.replace("\\", "\\\\").replace('"', '\\"')
             .replace("{", "\\{").replace("\n", "\\n"))
sdl = tmp.joinpath("tq_schema.graphql").read_text()
lines = ['import "../contrib/graphql/exec.mere";', 'let sdl = "%s";' % esc(sdl)]
for q in tmp.joinpath("type_queries.txt").read_text().split("\n"):
    if not q: continue
    lines.append('let _ = print (Gexec.run_json (Gparse.document ("%s" ++ sdl)) (GObj ([])) []);'
                 % esc(q))
lines.append("0")
tmp.joinpath("tq_subject.mere").write_text("\n".join(lines) + "\n")
PY
  cp "$TMP/tq_subject.mere" "$ROOT/examples/.gintro_tmp.mere"
  if run_subject "__type" "$ROOT/examples/.gintro_tmp.mere" "$TMP/tq_raw.txt"; then
    sed '$d' "$TMP/tq_raw.txt" > "$TMP/tq_got.txt"
    # Compared as PARSED JSON, so key order in our serialiser is not the subject.
    node -e "
const fs=require('fs');
const want=fs.readFileSync('$TMP/tq_want.txt','utf8').split('\n').filter(l=>l.length);
const got=fs.readFileSync('$TMP/tq_got.txt','utf8').split('\n').filter(l=>l.length);
const qs=fs.readFileSync('$TMP/type_queries.txt','utf8').split('\n').filter(l=>l.length);
let bad=0;
const strip = v => Array.isArray(v) ? v.map(strip)
  : (v && typeof v==='object'
      ? Object.fromEntries(Object.entries(v).filter(([k])=>k!=='description').map(([k,x])=>[k,strip(x)]))
      : v);
qs.forEach((q,i)=>{
  let a,b;
  try { a=JSON.stringify(strip(JSON.parse(want[i]))); } catch(e){ a='WANT-UNPARSEABLE'; }
  try { b=JSON.stringify(strip(JSON.parse(got[i]))); } catch(e){ b='OURS-UNPARSEABLE: '+String(got[i]).slice(0,120); }
  if (a!==b) { bad++;
    console.log('        ' + q.slice(0,86));
    console.log('          oracle: ' + String(a).slice(0,150));
    console.log('          ours  : ' + String(b).slice(0,150)); }
});
process.exit(bad===0?0:1);
" && echo "  ok    __type  $NTQ queries, including an unknown name and __Type itself" \
      || { echo "  FAIL  __type"; fail=1; }
  fi
fi

# --- 4. description is null, everywhere ---------------------------------
#
# `description` is stripped from BOTH sides in every comparison above, because the
# generated schema drops the oracle's prose (see gen_introspection_sdl.sh) and this
# executor never reports a description for a user's types either.
#
# A normalisation that hides a difference is exactly how a gap stops being stated,
# so the gap is asserted here instead: our answer must have `description: null`
# EVERYWHERE. The day descriptions land, this section fails and says so — which is
# what makes it a claim rather than a silence.
cat > "$TMP/desc_schema.graphql" <<'S'
"""the root"""
type Query { """a field""" a: Int }
S
python3 - "$TMP" <<'PY'
import sys, pathlib
tmp = pathlib.Path(sys.argv[1])
def esc(t):
    return (t.replace("\\", "\\\\").replace('"', '\\"')
             .replace("{", "\\{").replace("\n", "\\n"))
sdl = tmp.joinpath("desc_schema.graphql").read_text()
q = '{ __schema { types { name description fields { name description } } } }'
tmp.joinpath("desc_subject.mere").write_text(
  'import "../contrib/graphql/exec.mere";\n'
  'print (Gexec.run_json (Gparse.document ("%s" ++ "%s")) (GObj ([])) [])\n'
  % (esc(q), esc(sdl)))
PY
cp "$TMP/desc_subject.mere" "$ROOT/examples/.gintro_tmp.mere"
if run_subject "description" "$ROOT/examples/.gintro_tmp.mere" "$TMP/desc_raw.txt"; then
  sed '$d' "$TMP/desc_raw.txt" > "$TMP/desc.txt"
  node -e "
const d=JSON.parse(require('fs').readFileSync('$TMP/desc.txt','utf8'));
let seen=0, nonnull=[];
(function walk(v, path){
  if (Array.isArray(v)) return v.forEach((x,i)=>walk(x, path+'['+i+']'));
  if (v && typeof v==='object') for (const [k,x] of Object.entries(v)) {
    if (k==='description') { seen++; if (x!==null) nonnull.push(path+'.'+k+'='+JSON.stringify(x)); }
    else walk(x, path+'.'+k);
  }
})(d.data, '');
if (!seen) { console.log('        NO description FIELDS REACHED — the assertion is vacuous'); process.exit(1); }
if (nonnull.length) { console.log('        ' + nonnull.slice(0,4).join('\n        ')); process.exit(1); }
console.log('  ok    description  null at all ' + seen + ' positions (stated gap, asserted)');
" || { echo "  FAIL  description  the stated gap no longer holds — see gen_introspection_sdl.sh"; fail=1; }
fi

[ "$fail" = 0 ] && echo "graphql_intro_parity: ok" || echo "graphql_intro_parity: FAILED"
[ "$fail" = 0 ]
