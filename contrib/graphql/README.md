# contrib/graphql — GraphQL executable documents

A lexer, parser and printer for GraphQL's **executable** documents: operations
and fragments. Type-system definitions (SDL — `type`, `interface`, `input`,
`enum`, `schema`) are a separate grammar and are not parsed here yet.

## Files

| file | exports | lines |
|---|---|---|
| `ast.mere` | `gtok` / `gtype` / `gval` / `gdir` / `gsel` / `gvardef` / `gdef` — type-only | ~65 |
| `lexer.mere` | `module Glex { tokens, block_value }` | ~230 |
| `parser.mere` | `module Gparse { document }` | ~215 |
| `printer.mere` | `module Gprint { document, pval, ptype }` | ~150 |

`ast.mere` is type-only so the three others share one definition instead of
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
*has* a default, and it is null.

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
that admits a value, every selection form, every operation shape, and a set of
nested type expressions. 153 documents at the time of writing.

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

The other sections are round-trip, idempotence (the oracle's own output fed back
through us, so a printer that loses something on the first pass and is stable
afterwards cannot pass), and a corpus check that fails loudly if the **oracle**
rejects a document this harness generated — that is a bug in the generator, not
a result. It caught `007`, which is not a legal `IntValue`.

## Not here yet

- **SDL** (type-system definitions), validation, execution, introspection.
- **A block string whose value does not survive re-parsing** is *refused* by the
  printer, not approximated. Re-parsing applies the dedent rule again, so a value
  with common leading whitespace on its continuation lines comes back different;
  emitting it as an ordinary string instead would round-trip the text and lose
  `block: true` from the tree. A wrong answer that looked like a parser bug is
  worse than a refusal, so `Gprint` fails and names the value.
