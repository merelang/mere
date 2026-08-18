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

## Introspection

`__schema`, `__type(name:)` and `__typename`, answered by **the ordinary executor**.

### The schema is a file, and that is the whole design

The introspection types — `__Schema`, `__Type`, `__Field`, `__InputValue`,
`__EnumValue`, `__Directive`, `__TypeKind`, `__DirectiveLocation` — are ordinary
SDL, generated into `introspection_sdl.mere` and **appended to the document's own
definitions**. From there `__Type` is an object type like any other, so field
lookup, nullability, null propagation, list handling and enum coercion all apply to
it unchanged. There is no second executor and no introspection code path.

The SDL is **generated from graphql-js and committed**, the same arrangement as the
Unicode and HPACK tables: the specification fixes every name, type and nullability
in it, so typing it out would be a transcription, and a 200-line transcription has
a mistake in it. `graphql_intro_parity.sh` regenerates and diffs.

**Descriptions are dropped** from the generated schema — they are prose that no
answer here depends on, and keeping them would put the oracle's English in this
repo and make every graphql-js release a diff. That is a stated gap, and the gate
asserts `description` is null at every position rather than letting the
normalisation hide it.

### Introspection is cyclic, so one value has to be lazy

`__schema.types` lists every type, each type's `fields` name types, whose fields
name types. **A strict value cannot hold that** — building it eagerly does not
terminate — and what bounds the expansion is the query: `getIntrospectionQuery()`
asks for `ofType` exactly nine levels deep and stops.

So `gvalue` has one non-data arm, `GTypeRef of gtype`, carrying a type
*expression*; its `__Type` fields are computed when asked for. That makes it the
only place in this executor where a field is computed rather than looked up —
worth saying out loud, because everywhere else the resolvers are the data.

### Where arguments started mattering

This executor ignores field arguments, like graphql-js's default resolver. Two
places here cannot:

- **`__type(name:)`** — without its argument it is not a field, it is a different
  question.
- **`includeDeprecated`** on `fields` / `enumValues` / `inputFields` / `args`, whose
  default is **false**. Filtered in one place rather than at the four producers,
  because two of them build a `GObj` and two answer from a `GTypeRef`, so filtering
  at the source would be the same rule written twice in two shapes.

**The standard introspection query passes `includeDeprecated: true`**, so every
section of the gate that uses it agreed while this was missing entirely. It took a
hand-written `__type(name: "Colour") { enumValues }` — no argument, hence the
default — to disagree.

### The gate, and the check that is stronger than comparing

Four oracles for one feature:

1. the committed SDL vs a fresh generation
2. `getIntrospectionQuery()` — 109 lines nobody here wrote — executed on both sides
   and compared as JSON, over 11 schemas covering every `__TypeKind`
3. **the round trip**: our introspection result fed to graphql-js's own
   `buildClientSchema` and printed must equal `printSchema(buildSchema(sdl))`
4. `__type` by hand, including an unknown name and `__Type` itself

(3) is the one worth copying. It holds exactly when our answer carries the whole
schema, it is blind to field order (which the specification does not fix), and
**nothing transcribes an introspection result** — the same reason the document gate
compares printed documents rather than serialised ASTs. It passed before (2) did,
and the differences (2) then found were both real.

### Two things the oracle had to correct

- **A built-in scalar belongs to a schema only if something refers to it.** The
  oracle's type map for `type Query { a: Int }` is `Query Int Boolean String` and
  not the other two. `Boolean` and `String` are always present because the
  **built-in directives** refer to them — `@skip(if: Boolean!)`,
  `@deprecated(reason: String!)` — which falls out of walking the appended SDL
  rather than being special-cased.
- **graphql-js 17 keeps an argument's default in `a.default.value`**, not
  `a.defaultValue`. Reading the old field silently dropped
  `@deprecated(reason: String! = "No longer supported")`'s default, and the
  oracle's own introspection of our answer is what said so.

## Validation

19 of the specification's 32 rules, in `validate.mere`. Without it the executor
answered a malformed document by failing somewhere in the middle — a message about
an internal position rather than about the request.

```mere
Gvalid.report (Gparse.document query) (Gparse.document sdl)
// FieldsOnCorrectType	Cannot query field "nope" on type "Query".
```

### The document and the schema are separate arguments

Unlike the executor, which takes one list from parsing `query ++ sdl`. That is not
style: **`ExecutableDefinitions` is the rule that a document being executed must not
contain type-system definitions**, and in a combined list every schema it is
validated against violates it. The first version did exactly that and reported every
SDL type as "not executable". It is also how the oracle is called —
`validate(schema, document)` — so the comparison is not about an arrangement neither
side has.

### Every error carries the name of the rule that produced it

That is what makes a **partial** validator gateable, and it is the part worth
copying. The harness compares the **set of rule names** that fired against graphql-js
running each of its 32 rules individually — the oracle classifying its own output;
nothing here maps a message to a rule.

Two reasons rule names and not the error list, both measured:

1. graphql-js returns errors in **visitor order, interleaved across rules**:
   `{ a(x: 1, x: 2) }` yields `UniqueArgumentNames` then two `KnownArgumentNames`.
   Matching that list would require all 32 rules plus the traversal, so a partial
   validator could never agree about anything.
2. Rule names are a vocabulary of about thirty identifiers from the specification's
   own section titles — small enough that a shared misreading is not a real risk, the
   same argument the document gate makes for `Int` against `Float`.

Messages are compared too, as sorted sets: **every message we produce must be one
graphql-js produces.** `Did you mean ...` is stripped from the oracle's side, and the
harness fails if no oracle message carried one — a normalisation nothing exercises
is a claim about nothing.

### Three failures, not one

| | |
|---|---|
| we reject what the oracle accepts | the worst: a false positive fails a valid request |
| we miss a rule we **claim** | a real defect |
| we miss a rule we do **not** claim | DOCUMENTED-GAP — and the rule must be on the list |

A gap-list entry that never fires in the corpus **fails the harness as stale**. And
the claim list is checked in both directions: every rule we report must be on it.
Without that second direction, dropping a rule from the list while still implementing
it left the harness green — poisoning found it, because the list is otherwise
consulted only for rules that were *missed*. **A wrong list silently weakens every
check that reads it.**

### What the harness caught

- **We rejected `{ __schema { queryType { name } } }`.** `__schema`, `__type` and
  `__typename` are provided *by* the schema rather than declared in it, so a lookup
  reports them as unknown fields. A false positive, and the worst kind.
- **`is not defined by operation` versus `is never used in operation`** — two
  prepositions, and one shared helper put the wrong word in one of them.
- **A fragment cycle is reported once**, at the first fragment in document order,
  with the path through the others: `A -> B -> A` is one error naming A "via B" and
  not a second naming B.

## Arguments reach a resolver

A field's value may be a **function of its coerced arguments**, which is what
`user(id: 5)` needs. Everywhere else the resolvers are the data — a field is
resolved by looking its name up in the parent — and that is what makes the
execution gate meaningful, but it also meant a field's value could not depend on
an argument.

```mere
let root = GObj ([("user", GFn (fn (args) -> ...))]);
```

### The gate for this has to be different, and the difference is the point

A hand-written resolver now exists on **both** sides and the two could drift. So
the harness makes its resolvers **echo the arguments they received**, as JSON. The
resolver becomes trivial and the comparison moves onto argument **coercion**, which
is where the rules actually are. Every one of these was measured, and every one is a
distinction something could get wrong:

| | |
|---|---|
| omitted, has a schema default | present, with the default |
| default is `null` | present, `null` — which is how it differs from having no default |
| omitted, no default | **absent**, not null |
| written as `null` | present, `null` |
| variable **not supplied** | the argument was not written, so the schema default applies |
| variable supplied as `null` | present, `null` — an explicit null **beats** its own default |
| key order | the **field definition's** argument order, not the document's |

The sharpest case is `f(a: $v, b: $v)` with no `v`: it gives `{b: 7}`. One variable,
two outcomes, decided by the field definition — `b` falls back to its default and
`a`, which has none, is absent.

The explicit-null rule was a **bug**: `lookup_var` answers null both for "supplied
as null" and for "not supplied", and asking it was the mistake. It is not observable
without an argument-taking resolver, which is why it survived — the only other place
a variable is visible is `@skip` / `@include`, whose `if:` is `Boolean!`, so the
oracle answers a coercion error there rather than a different value.

`doc_value` also had to learn lists and input objects. It served only directive
arguments before, whose values are scalars, so it refused them **with a message
about directives** — which became wrong the moment field arguments started reaching
resolvers.

## The stack is compilable, and was not

Every gate here runs the **interpreter**. Until `test/parity/graphql_stack_portable.mere`
existed, nothing in this directory had ever been compiled to anything — and three
separate things were wrong with it:

- **A builtin passed as a value.** `take_while s i is_digit buf` hands `is_digit`
  over as a value, and no compiled backend supports that: C emitted `mu_is_digit`
  and failed in the C compiler, LLVM and Wasm refused with `unbound variable:
  is_digit`. The mechanism exists for both neighbours — a user function becomes
  `<name>_as_value`, an extern becomes `__ext_<name>_as_value` — and a builtin has
  no adapter because its C name lives in a per-backend `App` case rather than in a
  table. Wrapped in a lambda here; the general fix is the declarative builtin
  registry, and it is registered upstream.
- **Two inner functions captured a variable two levels of lifting away**, which LLVM
  reported as `unbound variable: declared` and Wasm as `inner-lifted capture
  'frags' not in scope`. Both take the value as a parameter now.

The parity program exercises lex, parse, print, validate, execute, introspect and an
argument-reading resolver, so every backend has to agree with the interpreter about
all of it. **A library that only ever runs interpreted has untested portability and
nothing says so.**

## Serving it

`examples/graphql_server.mere` is a GraphQL endpoint over HTTP/1.1, compiled with the
C backend and driven by `curl` in `scripts/graphql_server_parity.sh`.

**HTTP/1.1 on raw sockets rather than `contrib/http`**, which is Node-hosted — one
extern plus glue JS, needing a Wasm build and `node`. This runs natively, the same way
`examples/grpc_hello.mere` does, and for the same reason: a server you can hand
somebody as a binary. The HTTP handling lives in the example rather than in `contrib/`
until a second program needs it; a real HTTP/1.1 module owes a gate of its own for
keep-alive, chunked bodies and header folding, none of which are there.

### What that gate is for, and what it leaves alone

Execution, introspection and validation are each gated exhaustively against graphql-js
without a socket in sight. What is new is the **transport**, so that is what this
checks: request framing, `Content-Length`, header case, the error statuses, and that a
client which knows nothing about any of it gets JSON it can parse.

Three things it found, all of which a polite client hides:

- **The headers and the body can arrive in separate writes.** On loopback `curl` sends
  one packet, so a server that parses whatever the first read gave it passes every
  polite test. Removing the body-read loop does not fail the harness without a case
  that splits the request.
- **`content-length` is case-insensitive** and `curl` sends one spelling. A server that
  only accepts the case it was tested against works with exactly one client.
- **A valid request carrying an invalid query reached nothing.** Every other case was
  either a well-formed query or a broken request, so poisoning the endpoint to skip
  validation entirely left the gate green.

### And one thing the gate could not find, because there was nothing there

A non-ASCII fixture row went in to catch a `Content-Length` measured in characters. It
did not — **Mere's `str_len` already counts bytes** (`str_len "だいち"` is 9, and
`char_at` returns one byte), so the poison and the correct code were the same program
and no corpus could tell them apart. The round trip through `bytes_of_str` came out and
the comment claiming the two differed came out with it. The row stayed, for the thing it
does check: that a multi-byte body survives read, parse, execute, serialise and framing
unchanged.

## Not here yet

- **13 validation rules**, each named on the harness's gap list and each exercised by
  its corpus: `ValuesOfCorrectType`, `ProvidedRequiredArguments`,
  `VariablesInAllowedPosition`, `OverlappingFieldsCanBeMerged`,
  `PossibleFragmentSpreads`, `UniqueInputFieldNames`, `SingleFieldSubscriptions` and
  the rest.
- **`Did you mean ...` suggestions**, which need graphql-js's own ranking.
- **Source positions**, so no rule reports a location — the parser does not carry
  them, the same gap the executor has for `locations`.
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
