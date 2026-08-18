# contrib/graphql — GraphQL documents

A lexer, parser and printer for GraphQL documents: **executable** definitions
(operations and fragments) and **type-system** definitions (SDL — `schema`,
`scalar`, `type`, `interface`, `union`, `enum`, `input`, `directive`).

## Files

| file | exports | lines |
|---|---|---|
| `ast.mere` | `gtok` / `gtype` / `gval` / `gdir` / `ginpval` / `gfield` / `genumv` / `gopty` / `gtsdef` / `gsel` / `gvardef` / `gdef` — type-only | ~95 |
| `lexer.mere` | `module Glex { tokens, block_value }` | ~260 |
| `parser.mere` | `module Gparse { document }` | ~390 |
| `printer.mere` | `module Gprint { document, pval, ptype }` | ~230 |
| `exec.mere` | `type gvalue` / `gpath` / `gerr` / `gout`; `module Gexec { run, run_json, to_json }` | ~370 |

`ast.mere` is type-only so the other three share one definition instead of
three that drift — the same arrangement as `contrib/parser/ast.mere`.

## Usage

```mere
import "contrib/graphql/ast.mere";
import "contrib/graphql/lexer.mere";
import "contrib/graphql/parser.mere";
import "contrib/graphql/printer.mere";

Gprint.document (Gparse.document "{ a b(x: 1) @d { c } ...F }")
// query { a b(x: 1) @d { c } ...F }
```

Note that a literal `{` inside a Mere string is written `\{`, because `{...}` is
string interpolation. A lexer for a brace language cannot write its own brace
literals unescaped.

## Two representation choices, both load-bearing

- **`IntValue` and `FloatValue` keep their lexeme, not a parsed number.** That is
  what the specification's AST does and what graphql-js does. It is also the only
  shape that round-trips a literal the host language cannot hold: a document is
  not obliged to fit in an int64 because we parsed it.
- **A block string is a different constructor from a plain string.** graphql-js
  records `block: true`, so folding them together would make two different
  documents print the same — and the gate compares printed documents.

Absence is `""` for an alias, an operation name and a type condition. Those are
the three places the grammar allows a name to be missing, and none of them can
legally be empty, so the sentinel cannot collide with a real value.

A variable definition's default is a 0-or-1 element list rather than an option,
so that "absent" and "present and null" stay distinguishable: `$x: Int = null`
*has* a default, and it is null. **A description is the same shape** — a
`gval list`, not a `str` — because it has to carry the string's own kind:
graphql-js records `block: true` on it, so a description written as a block string
and printed as an ordinary one is a different tree.

## Empty blocks are not empty lists

Every delimited list in this grammar requires at least one element **except the
two that are values**: `[]` and `{}` are a legal empty list and a legal empty
object, while `{ }` as a selection set — or a fields block, an enum values block,
an input fields block, an argument list, an argument *definition* list, or a
schema body — is not legal at all.

The first version returned an empty list for all of them and so accepted six
documents the specification does not contain. The check now lives in one helper
that names the production, rather than at seven call sites.

## The gate

`scripts/graphql_parity.sh` checks against graphql-js, and the shape is the part
worth copying:

```
graphql-js:  print(parse(D))                    -> A
us:          Gprint.document (Gparse.document D) -> M
graphql-js:  print(parse(M))                    -> B
assert A == B
```

`print` is a function of the AST alone, so `A == B` holds exactly when the two
parses produced the same tree — **and nothing transcribes an AST**. The obvious
alternative (serialise both trees into a shared format and diff) requires writing
a serialiser for the oracle's tree, which can hold the same misreading as the
parser it is checking. A differential gate that shares a bug with its subject
reports agreement.

It also means this printer is not held to graphql-js's formatting, only to
emitting something that parses back the same. The output is deliberately plain,
one line, single spaces. It is not a pretty-printer.

The corpus is **derived**: a cross product of every value kind × every position
that admits a value, every selection form, every operation shape, nested type
expressions, and — for SDL — every definition kind × description form × directive
form, `implements` at several arities, and argument definitions with and without
defaults. **366 documents** at the time of writing.

### A round-trip is blind to anything that prints identically

Found by deliberately breaking the lexer so that **every** number became an
`IntValue`: the gate stayed green. The reason is structural — the printer emits a
numeric literal's lexeme unchanged, so `IntValue "1.0"` prints `1.0`, the oracle
re-parses it as a `FloatValue`, and the two printed documents agree. The input
reached the code; the distinction was not observable where the comparison
happened.

So the harness has a fourth section that asks for the kind directly. It is the
one place that transcribes anything from the oracle's tree, and the shared
vocabulary is two words (`Int`, `Float`) — small enough that a shared misreading
is not a real risk.

### Valid documents only would test nothing

Everything above feeds *valid* input, and a parser that accepts anything passes
all of it. So there is a **reject-list**: 37 documents the oracle rejects, which
must be rejected here too. Its first run found six real defects — the four empty
blocks above, plus `007` (an `IntValue` may not have a leading zero) and `1.`
(a fraction needs a digit). The lexer now also refuses a number followed by a
digit, a `.` or a name start, so `1.2.3` and `1abc` are errors rather than two
tokens.

The distinction being checked is not "does it error" but "does it error *instead
of* quietly producing a tree" — a parser that reads `{ a` as `{ a }` has invented
a closing brace, and nothing in the round-trip section would notice.

### A gate that aborts on its subject's crash reports nothing

`set -e` was right for the preflight and wrong for the sections. Deliberately
dropping `repeatable` from the parser made one corpus document unparseable, the
Mere process exited non-zero, and the harness **stopped in the middle having
printed no verdict** — taking the reject-list and numeric-kind sections with it.
The subject now runs through a helper that never aborts, names the section it
failed in, and lets the rest of the harness still run.

The other sections are round-trip, idempotence (the oracle's own output fed back
through us, so a printer that loses something on the first pass and is stable
afterwards cannot pass), and a corpus check that fails loudly if the **oracle**
rejects a document this harness generated — that is a bug in the generator, not
a result.

## Execution

`exec.mere` executes a document against data. **The resolvers are the data**: a
field is resolved by looking its name up in the parent object, which is what
graphql-js does by default. That is what makes `scripts/graphql_exec_parity.sh`
meaningful — with the default resolver on both sides, nothing about resolution is
transcribed, so a difference in the output is a difference in *execution* rather
than two hand-written resolver sets that drifted.

```mere
import "contrib/graphql/exec.mere";
Gexec.run_json (Gparse.document (query ++ sdl)) root_value variables
// {"data":{"a":1}}   or   {"errors":[{"message":"…","path":["a"]}],"data":{"a":null}}
```

### Null propagation is the hard part

A non-null field that resolves to null is **not** an error in that field — it
destroys the nearest **nullable** ancestor. `{ nn }` where `nn: Int!` answers
`"data": null`, not `"data": {"nn": null}`. An item error in `[Int!]` nulls the
whole list, with a path of `["ln", 1]`.

Every position is one of two things, and that is all `gout` says:

| | meaning |
|---|---|
| `GOk (value, errors)` | a value, possibly null, and whatever went wrong below |
| `GBubble errors` | this position could not be null and was; a nullable ancestor must absorb it |

Written that way, the four cases in the specification — field, list item, object,
top level — fall out of two constructors instead of needing exceptions the language
does not have.

**Where absorption happens is the whole subtlety, and the oracle found it.** The
first version absorbed inside the object and list arms, which is right for a
nullable position and wrong inside a `!`. Of 67 cases exactly one differed:
`{ o2 { nnx } }` with `o2: O!` produced *two* errors — the real one about `O.nnx`
and an invented one about `Query.o2` — where the oracle produces one. When a
non-null position is null **because an error already propagated**, no second error
is raised: the check that would raise it is never reached. So `raw` completes a
position with no absorbing and `complete` decides what the position's nullability
means. A list item goes through `complete`, so `[O]` nulls the item and `[O!]`
nulls the list; that falls out rather than being special-cased.

### What the gate compares, and what it does not

Data, errors, error paths, and the **order** of all of it — a GraphQL response's
field order follows the query, so it is compared as it comes rather than sorted.
Error messages are compared **verbatim**: the specification does not fix the prose,
so matching the reference implementation is the only way to compare messages at
all, and the oracle's version is pinned and printed.

`locations` are **stripped from both sides**. They need source positions the parser
does not carry — a stated gap, not an accident.

Poisoning it ten ways caught nine immediately. The tenth was a coverage gap worth
recording: breaking the **named** fragment's type-condition check went unnoticed
because the corpus only had the **inline** form, so one of two nearly identical
branches was unchecked. Three named-spread cases closed it.

## Not here yet

- **Validation and introspection** beyond `__typename`.
- **Type-system extensions** (`extend type T { … }`). Valid GraphQL that this
  parser refuses rather than mis-reads: reading `extend type T` as `type T` would
  produce a tree that says something the document did not. The refusal is
  *asserted* by the harness, so the day extensions land, that section fails and
  says the assertion is stale — the same discipline as a DIVERGE pin.
- **A block string whose value does not survive re-parsing** is *refused* by the
  printer, not approximated. Re-parsing applies the dedent rule again, so a value
  with common leading whitespace on its continuation lines comes back different;
  emitting it as an ordinary string instead would round-trip the text and lose
  `block: true` from the tree. A wrong answer that looked like a parser bug is
  worse than a refusal, so `Gprint` fails and names the value.
