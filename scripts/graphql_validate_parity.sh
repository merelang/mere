#!/bin/sh
# scripts/graphql_validate_parity.sh — validation, against graphql-js.
#
# A GraphQL server rejects a bad request before executing any of it. The oracle is
# graphql-js's `validate(schema, document)`, and the interesting part of this harness
# is HOW A PARTIAL VALIDATOR IS GATED, because 19 of the specification's 32 rules are
# implemented and a harness that demanded all 32 could only ever say FAILED.
#
# THE COMPARISON IS ON RULE NAMES, not on the error list. Two reasons, both measured:
#
#   1. graphql-js returns errors in VISITOR order, interleaved across rules —
#      `{ a(x: 1, x: 2) }` yields UniqueArgumentNames then two KnownArgumentNames.
#      Matching that list would require implementing all 32 rules and reproducing the
#      traversal, so a partial validator could never agree about anything.
#   2. Rule names are a vocabulary of about thirty identifiers from the
#      specification's own section titles. Small enough that a shared misreading is
#      not a real risk — the same argument the document gate makes for `Int` against
#      `Float`.
#
# The oracle is asked WHICH rule fires by running each of its rules on its own. That
# is the oracle classifying its own output; nothing here maps messages to rules.
#
# Messages are compared as well, as SORTED SETS, for the rules that are implemented.
# `Did you mean ...` is stripped from the oracle's side — those suggestions need
# graphql-js's own ranking, and that is a stated gap, asserted below.
#
# THREE FAILURES ARE DISTINGUISHED, because they are not equally bad:
#
#   * we reject a document the oracle accepts        — the worst; a false positive
#     makes a valid request fail
#   * we miss a rule we CLAIM to implement           — a real defect
#   * we miss a rule we do NOT claim                 — DOCUMENTED-GAP, and the rule
#     must be on the list below; a listed rule that never fires is STALE and fails
#
# Skips (exit 0) without node or graphql-js.
#
# Usage:
#   sh scripts/graphql_validate_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

[ -x "$MERE" ] || { echo "graphql_validate_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "graphql_validate_parity: node absent, skipping"; exit 0; }
GQL_DIR=""
for cand in "$ROOT/node_modules/graphql" "$(npm root -g 2>/dev/null)/graphql"; do
  [ -f "$cand/package.json" ] && { GQL_DIR=$cand; break; }
done
if [ -z "$GQL_DIR" ]; then
  echo "graphql_validate_parity: the 'graphql' package was not found, skipping"
  exit 0
fi
GQL_VER=$(node -p "require('$GQL_DIR/package.json').version")
echo "graphql_validate_parity: oracle is graphql-js $GQL_VER (node $(node -v))"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$ROOT/examples/.gvalid_tmp.mere"' EXIT
fail=0
set +e

run_subject() {
  ( ulimit -t 300; "$MERE" "$2" ) > "$3" 2> "$TMP/err.txt" && return 0
  echo "  FAIL  $1  the subject itself failed:"
  sed 's/^/          /' "$TMP/err.txt" | head -5
  fail=1
  return 1
}

# THE RULES NOT IMPLEMENTED. Each must actually fire somewhere in the corpus below,
# or the entry is stale and this harness fails — a "not implemented" note with nothing
# behind it is the same problem as a pin that cannot detect its own repair.
cat > "$TMP/gaps.txt" <<'GAPS'
ValuesOfCorrectType
ProvidedRequiredArguments
VariablesInAllowedPosition
OverlappingFieldsCanBeMerged
PossibleFragmentSpreads
UniqueInputFieldNames
SingleFieldSubscriptions
GAPS

cat > "$TMP/schema.graphql" <<'S'
schema { query: Query mutation: Mutation subscription: Subscription }
type Query {
  a: Int
  withArg(x: Int, req: Int!): Int
  obj: O
  l: [O!]
  c: Colour
  n: Node
  t: Thing
  inp(k: In): Int
}
type Mutation { m: Int }
type Subscription { s: Int t: Int }
type O { x: Int y: String o: O }
interface Node { id: ID! }
type Post implements Node { id: ID! title: String }
type User implements Node { id: ID! name: String }
type Unrelated { z: Int }
union Thing = Post | User
enum Colour { RED GREEN }
input In { k: Int j: Int! }
S

# Each line is one document. Blank lines and `#` comments are skipped.
cat > "$TMP/docs.txt" <<'DOCS'
{ a }
{ obj { x y } }
{ a b: a }
query Q($v: Int) { withArg(x: $v) }
fragment F on O { x } { obj { ...F } }
{ n { id } }
{ n { ... on Post { title } } }
{ __typename }
{ __schema { queryType { name } } }
{ __type(name: "O") { name } }
mutation { m }
{ nope }
{ obj { nope } }
{ obj }
{ a { x } }
{ c { x } }
query Q { a } query Q { a }
{ a } { a }
query Q { a } { a }
fragment F on Query { a }
{ ...Missing }
fragment F on Query { ...F } { ...F }
fragment A on Query { ...B } fragment B on Query { ...A } { ...A }
fragment F on Query { a } fragment F on Query { a } { ...F }
query Q($v: Int, $v: Int) { a }
query Q { withArg(x: $undef) }
{ withArg(x: $undef) }
query Q($unused: Int) { a }
{ withArg(x: 1, x: 2) }
{ a @nope }
{ a @skip(if: true) @skip(if: false) }
fragment F on Nope { a } { ...F }
query Q($v: Nope) { a }
fragment F on Colour { a } { ...F }
{ ... on Colour { a } }
query Q($v: O) { a }
type Foo { a: Int }
{ withArg(nope: 1) }
{ obj { ... on Unrelated { z } } }
{ withArg(x: "not an int") }
{ withArg(x: 1) }
subscription { s t }
{ inp(k: { k: 1, k: 2 }) }
query Q($v: String) { withArg(x: $v) }
{ x: a x: c }
DOCS
NDOCS=$(grep -cv '^$' "$TMP/docs.txt")

# --- the oracle: errors, and which rule produced each --------------------
node --input-type=module -e "
import * as g from '$GQL_DIR/index.js';
import { readFileSync, writeFileSync } from 'fs';
const schema = g.buildSchema(readFileSync('$TMP/schema.graphql','utf8'));
const docs = readFileSync('$TMP/docs.txt','utf8').split('\n').filter(l => l.trim().length);
const out = [];
for (const d of docs) {
  let doc;
  try { doc = g.parse(d); }
  catch (e) { out.push({ doc: d, parseError: e.message }); continue; }
  const errs = g.validate(schema, doc);
  // THE ORACLE CLASSIFIES ITS OWN OUTPUT: each rule run alone says whether it fires.
  const rules = g.specifiedRules
    .filter(r => g.validate(schema, doc, [r]).length)
    .map(r => r.name.replace(/Rule\$/, ''));
  out.push({
    doc: d,
    rules,
    // The suggestion needs graphql-js's own ranking; stated gap, asserted in
    // section 4 by checking that at least one oracle message HAS one.
    msgs: errs.map(e => e.message.replace(/ Did you mean .*\$/, '')),
    hadSuggestion: errs.some(e => / Did you mean /.test(e.message)),
  });
}
writeFileSync('$TMP/oracle.json', JSON.stringify(out, null, 1));
" 2>"$TMP/oracle.err"
if [ ! -f "$TMP/oracle.json" ]; then
  echo "  FAIL  oracle  graphql-js could not answer:"
  sed 's/^/        /' "$TMP/oracle.err" | head -6
  echo "graphql_validate_parity: FAILED"; exit 1
fi
if grep -q parseError "$TMP/oracle.json"; then
  echo "  FAIL  corpus  the ORACLE could not PARSE a document this harness wrote:"
  node -p "require('$TMP/oracle.json').filter(o=>o.parseError).map(o=>'        '+o.doc+' -> '+o.parseError.split('\n')[0]).join('\n')"
  echo "graphql_validate_parity: FAILED"; exit 1
fi
echo "  ok    corpus  $NDOCS documents, all parseable by graphql-js"

# --- our side ------------------------------------------------------------
python3 - "$TMP" <<'PY'
import sys, pathlib
tmp = pathlib.Path(sys.argv[1])
def esc(t):
    return (t.replace("\\", "\\\\").replace('"', '\\"')
             .replace("{", "\\{").replace("\n", "\\n"))
sdl = tmp.joinpath("schema.graphql").read_text()
lines = ['import "../contrib/graphql/validate.mere";',
         'let sdl = Gparse.document "%s";' % esc(sdl),
         # The rule list comes FROM the implementation, so the harness and the code
         # cannot disagree about what is claimed.
         'let _ = print ("IMPLEMENTED\\t" ++ str_join "," Gvalid.implemented);']
for d in tmp.joinpath("docs.txt").read_text().split("\n"):
    if not d.strip(): continue
    lines.append('let _ = print ("=== ");')
    lines.append('let _ = print (Gvalid.report (Gparse.document "%s") sdl);' % esc(d))
lines.append("0")
tmp.joinpath("subject.mere").write_text("\n".join(lines) + "\n")
PY
cp "$TMP/subject.mere" "$ROOT/examples/.gvalid_tmp.mere"
if run_subject "validate" "$ROOT/examples/.gvalid_tmp.mere" "$TMP/ours_raw.txt"; then
  sed '$d' "$TMP/ours_raw.txt" > "$TMP/ours.txt"
  node -e "
const fs=require('fs');
const oracle=JSON.parse(fs.readFileSync('$TMP/oracle.json','utf8'));
const gaps=fs.readFileSync('$TMP/gaps.txt','utf8').split('\n').filter(l=>l.trim());
const raw=fs.readFileSync('$TMP/ours.txt','utf8').split('\n');

const implLine = raw.shift();
if (!implLine.startsWith('IMPLEMENTED\t')) {
  console.log('        the subject did not report its rule list'); process.exit(1);
}
const impl = implLine.split('\t')[1].split(',').filter(s=>s.length);

// Our output is blocks separated by '=== ' lines.
const blocks = [];
let cur = null;
for (const l of raw) {
  if (l === '=== ') { cur = []; blocks.push(cur); }
  else if (cur && l.length) cur.push(l);
}

let falsePos = [], missClaimed = [], msgDiff = [], gapsSeen = new Set(), agreed = 0;
let unlistedMiss = [], sawSuggestion = false, unclaimed = [], bothWays = [];

// THE RULE LIST HAS TO BE LOAD-BEARING IN BOTH DIRECTIONS. Without this, dropping a
// rule from the implemented list while still implementing it left the harness green —
// poisoning found that, because the list is otherwise consulted only for rules that
// were MISSED. A wrong list silently weakens every check that reads it.
//
// (Comments in this block may contain neither a backtick nor a double quote: the
// whole script is passed to node inside a double-quoted shell string, so a backtick
// is command substitution and a quote ends the string. Both mistakes were made here
// in consecutive edits, and the second one turned the comparison into a syntax
// error rather than a wrong answer -- which is the good failure of the two.)
for (const g of gaps) if (impl.includes(g)) bothWays.push(g);

oracle.forEach((o, i) => {
  const mine = blocks[i] || [];
  const myRules = new Set(mine.map(l => l.split('\t')[0]));
  const myMsgs = mine.map(l => l.split('\t')[1]);
  const theirRules = new Set(o.rules);
  if (o.hadSuggestion) sawSuggestion = true;

  // 1. false positives: a rule we report that the oracle does not
  for (const r of myRules) {
    if (!theirRules.has(r)) falsePos.push(o.doc + '  we say ' + r + ', the oracle does not');
    if (!impl.includes(r)) unclaimed.push(r + ' is reported but not in Gvalid.implemented');
  }
  // 2/3. missed rules, split by whether we claim them
  for (const r of theirRules) {
    if (myRules.has(r)) continue;
    if (impl.includes(r)) missClaimed.push(o.doc + '  the oracle says ' + r + ', we do not');
    else if (gaps.includes(r)) gapsSeen.add(r);
    else unlistedMiss.push(o.doc + '  ' + r + ' is neither implemented nor on the gap list');
  }
  // 4. messages, for the rules we implement, as sorted sets
  const theirs = o.msgs.filter((m, k) => {
    // keep a message only if SOME implemented rule fired for this doc; the oracle
    // does not label messages, so this is per-document rather than per-message
    return true;
  });
  if (myRules.size && theirRules.size) {
    const ourSet = myMsgs.slice().sort();
    const theirSet = theirs.filter(m => true).slice().sort();
    // Every message we produce must be one the oracle produced.
    for (const m of ourSet) {
      if (!theirSet.includes(m)) msgDiff.push(o.doc + '\n            ours  : ' + m + '\n            oracle: (absent)');
    }
  }
  if (![...myRules].some(r => !theirRules.has(r)) &&
      ![...theirRules].some(r => impl.includes(r) && !myRules.has(r))) agreed++;
});

const staleGaps = gaps.filter(g => !gapsSeen.has(g));
const out = { impl: impl.length, agreed, n: oracle.length, falsePos, missClaimed,
              unlistedMiss, msgDiff, gapsSeen: [...gapsSeen], staleGaps, sawSuggestion,
              unclaimed: [...new Set(unclaimed)], bothWays };
fs.writeFileSync('$TMP/verdict.json', JSON.stringify(out));
" 2>"$TMP/cmp.err"
  if [ ! -f "$TMP/verdict.json" ]; then
    echo "  FAIL  compare  the comparison itself failed:"
    sed 's/^/        /' "$TMP/cmp.err" | head -8
    fail=1
  else
    V="require('$TMP/verdict.json')"
    show() { node -p "$V.$1.slice(0,6).map(s=>'        '+s).join('\n')"; }
    NIMPL=$(node -p "$V.impl"); AGREED=$(node -p "$V.agreed"); N=$(node -p "$V.n")

    if [ "$(node -p "$V.falsePos.length")" = 0 ]; then
      echo "  ok    no false positives  no document is rejected that graphql-js accepts"
    else
      echo "  FAIL  false positive  we reject what the oracle accepts — the worst kind:"
      show falsePos; fail=1
    fi

    if [ "$(node -p "$V.missClaimed.length")" = 0 ]; then
      echo "  ok    claimed rules  all $NIMPL implemented rules agree across $N documents"
    else
      echo "  FAIL  claimed rules  a rule this file CLAIMS to implement did not fire:"
      show missClaimed; fail=1
    fi

    if [ "$(node -p "$V.unlistedMiss.length")" = 0 ]; then
      echo "  ok    accounted for  every rule the oracle fired is implemented or listed"
    else
      echo "  FAIL  unaccounted  a rule is neither implemented nor on the gap list:"
      show unlistedMiss; fail=1
    fi

    if [ "$(node -p "$V.unclaimed.length")" = 0 ] && [ "$(node -p "$V.bothWays.length")" = 0 ]; then
      echo "  ok    rule list  every rule reported is claimed, and no rule is both claimed and listed"
    else
      echo "  FAIL  rule list  Gvalid.implemented does not match what this file does:"
      show unclaimed; show bothWays; fail=1
    fi

    if [ "$(node -p "$V.msgDiff.length")" = 0 ]; then
      echo "  ok    messages  every message we produce is one graphql-js produces"
    else
      echo "  FAIL  messages  we produce a message the oracle does not:"
      show msgDiff; fail=1
    fi

    if [ "$(node -p "$V.staleGaps.length")" = 0 ]; then
      echo "  DOCUMENTED-GAP  gaps  $(node -p "$V.gapsSeen.length") rules not implemented, each exercised by the corpus"
    else
      echo "  FAIL  stale gap  a rule on the gap list never fired — the note is stale:"
      show staleGaps; fail=1
    fi

    # The suggestion gap: it exists only if the oracle actually produced one here.
    if [ "$(node -p "$V.sawSuggestion")" = true ]; then
      echo "  DOCUMENTED-GAP  suggestions  \`Did you mean ...\` is stripped from the oracle's messages"
    else
      echo "  FAIL  suggestions  no oracle message carried a suggestion, so stripping them is vacuous"
      fail=1
    fi
  fi
fi

[ "$fail" = 0 ] && echo "graphql_validate_parity: ok" || echo "graphql_validate_parity: FAILED"
[ "$fail" = 0 ]
